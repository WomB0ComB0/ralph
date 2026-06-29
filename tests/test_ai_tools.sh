#!/bin/bash
# TDD harness for the AI-tool command builder (_build_ai_cmd in lib/engine.sh).
# Pure: builds argv into _AI_CMD[] + _AI_STDIN without executing any real CLI.
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export VERBOSE=false
# shellcheck disable=SC1090
source "$R/lib/utils.sh"
source "$R/lib/engine.sh"
set +eu
IFS=' '   # libs set IFS=$'\n\t'; use spaces so "${_AI_CMD[*]}" joins readably for matching

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (exp [$2] got [$3])"; fi; }

echo "== claude: headless (-p/--print) + model, prompt-as-arg =="
_build_ai_cmd claude "m1"; eq "claude rc" 0 "$?"
[[ "${_AI_CMD[*]}" == *" -p "* || "${_AI_CMD[*]}" == *" --print"* || "${_AI_CMD[*]}" == *"-p "* ]] && ok "claude is headless (-p/--print)" || bad "claude MISSING -p/--print: ${_AI_CMD[*]}"
[[ "${_AI_CMD[*]}" == *"--model m1"* ]] && ok "claude passes --model" || bad "claude no model: ${_AI_CMD[*]}"
eq "claude not stdin" 0 "$_AI_STDIN"

echo "== claude robustness: collapsed perms, fallback model, opt-in budget =="
_build_ai_cmd claude opus
[[ "${_AI_CMD[*]}" == *"--dangerously-skip-permissions"* ]] && ok "claude keeps --dangerously-skip-permissions" || bad "claude lost skip-perms"
[[ "${_AI_CMD[*]}" != *"--permission-mode"* ]] && ok "claude drops the redundant --permission-mode" || bad "redundant --permission-mode still present"
[[ "${_AI_CMD[*]}" == *"--fallback-model sonnet"* ]] && ok "claude(opus) has --fallback-model sonnet" || bad "no fallback: ${_AI_CMD[*]}"
[[ "${_AI_CMD[*]}" != *"--max-budget-usd"* ]] && ok "no budget cap by default" || bad "budget set without env"
export RALPH_MAX_BUDGET_USD=5; _build_ai_cmd claude opus
[[ "${_AI_CMD[*]}" == *"--max-budget-usd 5"* ]] && ok "budget cap when RALPH_MAX_BUDGET_USD set" || bad "no budget with env"
export RALPH_MAX_BUDGET_USD="5.50"; _build_ai_cmd claude opus
[[ "${_AI_CMD[*]}" == *"--max-budget-usd 5.50"* ]] && ok "decimal budget accepted" || bad "decimal budget rejected"
export RALPH_MAX_BUDGET_USD="1.2.3"; _build_ai_cmd claude opus
[[ "${_AI_CMD[*]}" != *"--max-budget-usd"* ]] && ok "malformed budget (1.2.3) rejected" || bad "malformed budget accepted"
unset RALPH_MAX_BUDGET_USD
_build_ai_cmd claude sonnet
[[ "${_AI_CMD[*]}" != *"--fallback-model"* ]] && ok "no redundant fallback when primary==fallback (sonnet)" || bad "fallback duplicates the primary"

echo "== claude no longer forces ANTHROPIC_BASE_URL to a local Ollama port =="
unset ANTHROPIC_BASE_URL
v=$( _apply_tool_env claude; echo "${ANTHROPIC_BASE_URL:-UNSET}" )
[[ "$v" == "UNSET" ]] && ok "claude uses real Anthropic auth (no forced localhost:11434)" || bad "forced ANTHROPIC_BASE_URL=$v"

echo "== opencode: run --model, prompt-as-arg =="
_build_ai_cmd opencode "prov/mod"
[[ "${_AI_CMD[*]}" == "opencode run --model prov/mod" ]] && ok "opencode run --model" || bad "opencode cmd: ${_AI_CMD[*]}"
eq "opencode not stdin" 0 "$_AI_STDIN"

echo "== agy: --model wired (agy DOES accept it), --print must stay LAST =="
_build_ai_cmd agy "Gemini 3.5 Flash (Low)"; eq "agy rc" 0 "$?"
[[ "${_AI_CMD[*]}" == *"--dangerously-skip-permissions"* ]] && ok "agy auto-approves" || bad "agy no skip-perms"
[[ "${_AI_CMD[*]}" == *"--model Gemini 3.5 Flash (Low)"* ]] && ok "agy passes --model when set" || bad "agy dropped --model: ${_AI_CMD[*]}"
# --print consumes the NEXT token as the prompt, so it MUST be the final flag in _AI_CMD;
# run_ai_tool appends "$prompt" after it -> `agy ... --print "<prompt>"`.
eq "agy --print is the LAST element" "--print" "${_AI_CMD[$((${#_AI_CMD[@]}-1))]}"
_build_ai_cmd agy ""; [[ "${_AI_CMD[*]}" != *"--model"* ]] && ok "agy omits --model when empty (self-selects)" || bad "agy passed empty --model"
eq "agy not stdin" 0 "$_AI_STDIN"

echo "== amp: stdin-piped + allow-all =="
_build_ai_cmd amp "m"
eq "amp uses stdin" 1 "$_AI_STDIN"
[[ "${_AI_CMD[*]}" == *"--dangerously-allow-all"* ]] && ok "amp allow-all" || bad "amp flags: ${_AI_CMD[*]}"

echo "== unknown tool rejected =="
_build_ai_cmd bogus "m"; eq "unknown tool rc=1" 1 "$?"

echo "== codex: exec subcommand, sandboxed, NO dangerous bypass, NO -p (would hang TUI) =="
_build_ai_cmd codex ""; eq "codex rc" 0 "$?"
[[ "${_AI_CMD[*]}" == "codex exec "* ]] && ok "codex uses exec subcommand" || bad "codex not exec: ${_AI_CMD[*]}"
[[ "${_AI_CMD[*]}" == *"-s workspace-write"* ]] && ok "codex sandboxed (workspace-write)" || bad "codex no sandbox"
[[ "${_AI_CMD[*]}" == *"--color never"* ]] && ok "codex --color never (clean tee'd logs)" || bad "codex no --color never"
[[ "${_AI_CMD[*]}" == *"--skip-git-repo-check"* ]] && ok "codex --skip-git-repo-check" || bad "codex missing skip-git"
[[ " ${_AI_CMD[*]} " != *" -p "* && "${_AI_CMD[*]}" != *"--print"* ]] && ok "codex avoids -p/--print" || bad "codex has -p/--print (TUI hang risk)"
eq "codex not stdin" 0 "$_AI_STDIN"
[[ "${_AI_CMD[*]}" != *"--model"* ]] && ok "no --model when empty (codex self-selects)" || bad "codex passed empty model"
_build_ai_cmd codex "gpt-5-codex"; [[ "${_AI_CMD[*]}" == *"--model gpt-5-codex"* ]] && ok "codex passes --model when set" || bad "codex no --model when set"
eq "resolve_model_for_tool codex -> empty (self-select)" "" "$(resolve_model_for_tool codex engineer)"

echo "== _ralph_is_valid_tool accepts all wired tools, rejects bogus =="
for t in opencode claude amp agy codex; do _ralph_is_valid_tool "$t" && ok "valid: $t" || bad "rejected valid tool: $t"; done
_ralph_is_valid_tool gemini && bad "gemini (deprecated CLI) accepted" || ok "gemini rejected (deprecated)"
_ralph_is_valid_tool bogus && bad "bogus accepted" || ok "bogus rejected"

echo "== _ai_timeout_secs: per-call wall-clock budget =="
unset RALPH_TOOL_TIMEOUT;     eq "default 1800s"          1800 "$(_ai_timeout_secs)"
export RALPH_TOOL_TIMEOUT=600; eq "custom respected"       600  "$(_ai_timeout_secs)"
export RALPH_TOOL_TIMEOUT=abc; eq "non-numeric -> default" 1800 "$(_ai_timeout_secs)"
export RALPH_TOOL_TIMEOUT=0;   eq "0 disables (returns 0)" 0    "$(_ai_timeout_secs)"

echo "== agy gets --print-timeout (still --print last) when timeout enabled =="
export RALPH_TOOL_TIMEOUT=600; _build_ai_cmd agy "m"
[[ "${_AI_CMD[*]}" == *"--print-timeout 600s"* ]] && ok "agy --print-timeout wired" || bad "agy no --print-timeout: ${_AI_CMD[*]}"
eq "agy --print still last (timeout before it)" "--print" "${_AI_CMD[$((${#_AI_CMD[@]}-1))]}"
export RALPH_TOOL_TIMEOUT=0; _build_ai_cmd agy "m"
[[ "${_AI_CMD[*]}" != *"--print-timeout"* ]] && ok "timeout disabled -> no --print-timeout" || bad "print-timeout present when disabled"
unset RALPH_TOOL_TIMEOUT

echo "== _timeout_bin: prefers timeout, falls back to gtimeout (macOS coreutils) =="
tb=$(_timeout_bin)
[[ "$tb" == "timeout" || "$tb" == "gtimeout" || -z "$tb" ]] && ok "_timeout_bin returns a valid value ([$tb])" || bad "unexpected _timeout_bin: $tb"
{ [[ -z "$tb" ]] || command -v "$tb" >/dev/null; } && ok "_timeout_bin names an installed binary (or none)" || bad "_timeout_bin named a missing binary: $tb"

echo "== per-tool env is subshell-scoped (must NOT leak to the parent) =="
unset CI ANTHROPIC_BASE_URL 2>/dev/null
( _apply_tool_env opencode ); [[ -z "${CI:-}" ]] && ok "opencode CI=true does not leak to parent" || bad "CI leaked to parent"
( _apply_tool_env claude ); [[ -z "${ANTHROPIC_BASE_URL:-}" ]] && ok "claude ANTHROPIC_BASE_URL does not leak" || bad "ANTHROPIC_BASE_URL leaked to parent"

echo "== capture: stderr -> log only; stdout (the answer) -> output_file =="
cdir=$(mktemp -d); lf="$cdir/log"; of="$cdir/out"
# exact redirection run_ai_tool uses: 2>>log | tee -a log > out
( bash -c 'echo ANSWER; echo DIAG >&2' 2>>"$lf" | tee -a "$lf" > "$of" )
eq "output_file holds only stdout (clean answer)" "ANSWER" "$(cat "$of")"
grep -q DIAG "$lf" && ok "stderr captured in the log" || bad "stderr missing from log"
grep -q DIAG "$of" && bad "stderr leaked into output_file" || ok "stderr NOT in output_file"
# guard against regressing to 2>&1 in run_ai_tool
grep -q '2>&1 | tee -a "\$log_file"' "$R/lib/engine.sh" && bad "run_ai_tool still merges stderr (2>&1) into output" || ok "run_ai_tool separates stderr from the result file"
rm -rf "$cdir"

printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
