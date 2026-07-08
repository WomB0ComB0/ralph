#!/usr/bin/env python3
"""Tiny local coding-agent adapter for Ralph + Ollama.

The model returns JSON actions. This adapter validates and executes those actions
inside PROJECT_DIR, then feeds observations back until the model finishes or the
iteration cap is reached.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import signal
import textwrap
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

DENY_COMMAND_PATTERNS = [
    r"\brm\s+-rf\b",
    r"\bsudo\b",
    r"\bsu\b",
    r"\bshutdown\b",
    r"\breboot\b",
    r"\bgit\s+push\b",
    r"\bgit\s+reset\s+--hard\b",
    r"\bgit\s+checkout\s+--\b",
    r"\bmkfs\b",
    r"\bdd\s+if=",
]

# IMPROVEMENT: Move the command allowlist into a project-local policy file so teams can tune safe commands without editing the executor.
ALLOW_COMMAND_PREFIXES = (
    "npm ", "npm", "node ", "node", "python3 ", "python3", "python ", "python",
    "bash ", "sh ", "git status", "git diff", "git add", "git commit", "git log",
    "ls", "find ", "rg ", "grep ", "sed ", "cat ", "mkdir ", "touch ",
)

WRITE_BLOCKLIST = {".git", ".hg", ".svn", "node_modules", "dist", "build", ".ralph"}


def eprint(*args: object) -> None:
    print(*args, file=sys.stderr)


def ollama_base() -> str:
    base = os.environ.get("OLLAMA_BASE_URL") or os.environ.get("OLLAMA_HOST") or "http://127.0.0.1:11434"
    base = base.rstrip("/")
    if base.endswith("/v1"):
        base = base[:-3]
    return base


def _alarm_handler(signum: int, frame: Any) -> None:
    raise TimeoutError("ollama request timed out")


def post_chat(model: str, messages: list[dict[str, str]], timeout: int) -> str:
    payload = {
        "model": model,
        "messages": messages,
        "stream": False,
        "think": os.environ.get("RALPH_OLLAMA_THINK", "false").lower() == "true",
        "format": "json",
        "options": {
            "temperature": float(os.environ.get("RALPH_OLLAMA_AGENT_TEMPERATURE", "0")),
            "num_predict": int(os.environ.get("RALPH_OLLAMA_AGENT_NUM_PREDICT", "2048")),
        },
    }
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        f"{ollama_base()}/api/chat",
        data=data,
        headers={"content-type": "application/json"},
        method="POST",
    )
    old_handler = signal.signal(signal.SIGALRM, _alarm_handler)
    signal.alarm(max(1, timeout))
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old_handler)
    return body.get("message", {}).get("content", "") or body.get("response", "") or ""


def extract_json(text: str) -> dict[str, Any]:
    text = text.strip()
    if text.startswith("```"):
        text = re.sub(r"^```(?:json)?\s*", "", text)
        text = re.sub(r"\s*```$", "", text)
    try:
        value = json.loads(text)
    except json.JSONDecodeError:
        start, end = text.find("{"), text.rfind("}")
        if start < 0 or end < start:
            raise
        value = json.loads(text[start : end + 1])
    if not isinstance(value, dict):
        raise ValueError("model response must be a JSON object")
    return value


def project_root() -> Path:
    root = Path(os.environ.get("PROJECT_DIR") or os.getcwd()).resolve()
    if not root.exists():
        raise RuntimeError(f"PROJECT_DIR does not exist: {root}")
    return root


def safe_path(root: Path, raw: str, *, write: bool = False) -> Path:
    if not raw or "\x00" in raw:
        raise ValueError("invalid path")
    path = (root / raw).resolve()
    if path != root and root not in path.parents:
        raise PermissionError(f"path escapes project: {raw}")
    rel_parts = path.relative_to(root).parts
    if write and any(part in WRITE_BLOCKLIST for part in rel_parts):
        raise PermissionError(f"refusing to write generated/internal path: {raw}")
    return path


def list_files(root: Path, raw: str = ".", limit: int = 200) -> dict[str, Any]:
    base = safe_path(root, raw)
    files: list[str] = []
    if base.is_file():
        return {"files": [str(base.relative_to(root))]}
    for path in sorted(base.rglob("*")):
        rel = path.relative_to(root)
        if any(part in {".git", "node_modules", "dist", "build"} for part in rel.parts):
            continue
        files.append(str(rel) + ("/" if path.is_dir() else ""))
        if len(files) >= limit:
            break
    return {"files": files}


def read_file(root: Path, raw: str, max_bytes: int = 20000) -> dict[str, Any]:
    path = safe_path(root, raw)
    data = path.read_bytes()[:max_bytes]
    return {"path": str(path.relative_to(root)), "content": data.decode("utf-8", "replace")}


def write_file(root: Path, raw: str, content: str, append: bool = False) -> dict[str, Any]:
    path = safe_path(root, raw, write=True)
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = "a" if append else "w"
    with path.open(mode, encoding="utf-8") as fh:
        fh.write(content)
    return {"path": str(path.relative_to(root)), "bytes": len(content.encode("utf-8")), "append": append}


def command_allowed(command: str) -> bool:
    stripped = command.strip()
    if not stripped:
        return False
    if any(re.search(pattern, stripped, re.IGNORECASE) for pattern in DENY_COMMAND_PATTERNS):
        return False
    return any(stripped == prefix.strip() or stripped.startswith(prefix) for prefix in ALLOW_COMMAND_PREFIXES)


def run_command(root: Path, command: str, timeout: int) -> dict[str, Any]:
    if not command_allowed(command):
        raise PermissionError(f"command not allowed: {command}")
    proc = subprocess.run(
        ["bash", "-lc", command],
        cwd=root,
        text=True,
        capture_output=True,
        timeout=timeout,
    )
    out = (proc.stdout or "")[-12000:]
    err = (proc.stderr or "")[-12000:]
    return {"command": command, "returncode": proc.returncode, "stdout": out, "stderr": err}


def run_action(root: Path, action: dict[str, Any], command_timeout: int) -> dict[str, Any]:
    tool = action.get("tool")
    try:
        if tool == "list_files":
            return {"ok": True, "tool": tool, **list_files(root, str(action.get("path", ".")), int(action.get("limit", 200)))}
        if tool == "read_file":
            return {"ok": True, "tool": tool, **read_file(root, str(action.get("path", "")), int(action.get("max_bytes", 20000)))}
        if tool == "write_file":
            return {"ok": True, "tool": tool, **write_file(root, str(action.get("path", "")), str(action.get("content", "")), False)}
        if tool == "append_file":
            return {"ok": True, "tool": tool, **write_file(root, str(action.get("path", "")), str(action.get("content", "")), True)}
        if tool == "run_command":
            return {"ok": True, "tool": tool, **run_command(root, str(action.get("command", "")), command_timeout)}
        if tool == "finish":
            return {"ok": True, "tool": tool, "summary": str(action.get("summary", "finished"))}
        return {"ok": False, "tool": tool, "error": "unknown tool"}
    except Exception as exc:  # noqa: BLE001 - report tool error to model
        return {"ok": False, "tool": tool, "error": f"{type(exc).__name__}: {exc}"}


def instruction_block(root: Path) -> str:
    return textwrap.dedent(f"""
    You are Ralph's local coding agent. Work only inside this project:
    {root}

    Reply with exactly one JSON object. No markdown. Schema:
    {{
      "message": "short status",
      "status": "continue" | "complete" | "blocked",
      "actions": [
        {{"tool":"list_files","path":".","limit":100}},
        {{"tool":"read_file","path":"relative/path"}},
        {{"tool":"write_file","path":"relative/path","content":"full file content"}},
        {{"tool":"append_file","path":"relative/path","content":"text to append"}},
        {{"tool":"run_command","command":"npm test"}},
        {{"tool":"finish","summary":"what changed and what passed"}}
      ]
    }}

    Rules:
    - Prefer small, complete changes.
    - Write full file contents for write_file.
    - Run tests/build commands when code changes.
    - finish only reports completion; it does not create, edit, or verify anything.
    - Do not use finish/status=complete until after at least one meaningful action for change requests.
    - Meaningful actions are write_file, append_file, or run_command.
    - Use status=complete only after verification or when no more work is required.
    - Use status=blocked with a clear message if the project cannot progress safely.
    """).strip()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--iterations", type=int, default=int(os.environ.get("RALPH_OLLAMA_AGENT_STEPS", "8")))
    parser.add_argument("--timeout", type=int, default=int(os.environ.get("RALPH_OLLAMA_AGENT_TIMEOUT", "180")))
    parser.add_argument("--command-timeout", type=int, default=int(os.environ.get("RALPH_OLLAMA_COMMAND_TIMEOUT", "120")))
    args = parser.parse_args()

    prompt = sys.stdin.read()
    root = project_root()
    messages = [
        {"role": "system", "content": instruction_block(root)},
        {"role": "user", "content": prompt[-60000:]},
    ]
    transcript: list[dict[str, Any]] = []
    meaningful_action_seen = False

    for step in range(1, args.iterations + 1):
        started = time.time()
        try:
            raw = post_chat(args.model, messages, args.timeout)
            response = extract_json(raw)
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, ValueError) as exc:
            messages.append({"role": "assistant", "content": raw if "raw" in locals() else ""})
            messages.append({"role": "user", "content": f"Your response was invalid JSON or failed: {exc}. Reply with valid JSON actions only."})
            continue

        actions = response.get("actions") or []
        if not isinstance(actions, list):
            actions = []
        dict_actions = [action for action in actions if isinstance(action, dict)]
        finish_actions = [action for action in dict_actions if action.get("tool") == "finish"]
        work_actions = [action for action in dict_actions if action.get("tool") != "finish"]

        observations = [run_action(root, action, args.command_timeout) for action in work_actions]
        if any(obs.get("ok") and obs.get("tool") in {"write_file", "append_file", "run_command"} for obs in observations):
            meaningful_action_seen = True

        wants_done = bool(finish_actions) or response.get("status") in {"complete", "blocked"}
        if finish_actions and meaningful_action_seen:
            observations.extend(run_action(root, action, args.command_timeout) for action in finish_actions)
        elif wants_done and not meaningful_action_seen and response.get("status") != "blocked":
            observations.append({
                "ok": False,
                "tool": "finish",
                "error": "premature finish rejected: finish only reports completion; execute write_file, append_file, or run_command first",
            })
            response["status"] = "continue"
            wants_done = False

        transcript.append({"step": step, "message": response.get("message", ""), "status": response.get("status", "continue"), "observations": observations, "elapsed_ms": int((time.time() - started) * 1000)})

        if wants_done:
            print(json.dumps({"status": response.get("status", "complete"), "model": args.model, "steps": transcript}, indent=2))
            return 0 if response.get("status") != "blocked" else 2

        messages.append({"role": "assistant", "content": json.dumps(response)})
        messages.append({"role": "user", "content": "Tool observations:\n" + json.dumps(observations, indent=2) + "\nContinue with the next JSON action set. If you need to change the project, use write_file/append_file before finish."})

    print(json.dumps({"status": "blocked", "model": args.model, "reason": "step limit reached", "steps": transcript}, indent=2))
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
