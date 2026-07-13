#!/bin/bash
# TDD harness for the AI-tool command builder (_build_ai_cmd in lib/engine.sh).
# Pure: builds argv into _AI_CMD[] + _AI_STDIN without executing any real CLI.
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export VERBOSE=false
# shellcheck disable=SC1090
source "$R/lib/utils.sh"
source "$R/lib/processes.sh"
source "$R/lib/engine.sh"
set +eu
IFS=' '   # libs set IFS=$'\n\t'; use spaces so "${_AI_CMD[*]}" joins readably for matching

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (exp [$2] got [$3])"; fi; }
valid_test_pid() { local pid="${1:-}"; [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 1 )); }
test_pid_alive() { valid_test_pid "${1:-}" && kill -0 "$1" 2>/dev/null; }
kill_test_pids() {
    local pid
    for pid in "$@"; do
        valid_test_pid "$pid" && kill -KILL "$pid" 2>/dev/null || true
    done
}

echo "== claude: headless (-p/--print) + model, prompt-as-arg =="
_build_ai_cmd claude "m1"; eq "claude rc" 0 "$?"
[[ "${_AI_CMD[*]}" == *" -p "* || "${_AI_CMD[*]}" == *" --print"* || "${_AI_CMD[*]}" == *"-p "* ]] && ok "claude is headless (-p/--print)" || bad "claude MISSING -p/--print: ${_AI_CMD[*]}"
[[ "${_AI_CMD[*]}" == *"--model m1"* ]] && ok "claude passes --model" || bad "claude no model: ${_AI_CMD[*]}"
eq "claude not stdin" 0 "$_AI_STDIN"
# empty model -> the --model flag is OMITTED (tool self-selects), not passed as `--model ""`
_build_ai_cmd opencode ""; [[ "${_AI_CMD[*]}" != *"--model"* ]] && ok "opencode empty model omits --model (self-select)" || bad "opencode passed empty --model: ${_AI_CMD[*]}"
_build_ai_cmd opencode "x/y"; [[ "${_AI_CMD[*]}" == *"--model x/y"* ]] && ok "opencode non-empty model still passes --model" || bad "opencode dropped model: ${_AI_CMD[*]}"
_build_ai_cmd claude "";   [[ "${_AI_CMD[*]}" != *"--model"* ]] && ok "claude empty model omits --model" || bad "claude passed empty --model: ${_AI_CMD[*]}"

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

echo "== session resume (opt-in, 3rd arg): --continue for claude/opencode/agy; codex/amp degrade =="
_build_ai_cmd claude m 1; [[ "${_AI_CMD[*]}" == *"--continue"* ]] && ok "claude resume -> --continue" || bad "claude resume no --continue: ${_AI_CMD[*]}"
_build_ai_cmd claude m 0; [[ "${_AI_CMD[*]}" != *"--continue"* ]] && ok "claude no-resume -> no --continue" || bad "claude --continue without resume"
_build_ai_cmd claude m;   [[ "${_AI_CMD[*]}" != *"--continue"* ]] && ok "claude default (2-arg) -> no --continue" || bad "claude --continue by default"
_build_ai_cmd opencode m 1; [[ "${_AI_CMD[*]}" == *"--continue"* ]] && ok "opencode resume -> --continue" || bad "opencode resume no --continue: ${_AI_CMD[*]}"
_build_ai_cmd agy m 1; [[ "${_AI_CMD[*]}" == *"--continue"* ]] && ok "agy resume -> --continue" || bad "agy resume no --continue: ${_AI_CMD[*]}"
eq "agy --print still last with resume" "--print" "${_AI_CMD[$((${#_AI_CMD[@]}-1))]}"
_build_ai_cmd codex "" 1; [[ "${_AI_CMD[*]}" != *"--continue"* && "${_AI_CMD[*]}" != *" resume"* ]] && ok "codex ignores resume (keeps sandboxed fresh exec)" || bad "codex tried to resume: ${_AI_CMD[*]}"
_build_ai_cmd amp m 1; [[ "${_AI_CMD[*]}" != *"--continue"* ]] && ok "amp ignores resume (no safe headless resume)" || bad "amp tried --continue"

echo "== _should_resume: gated on opt-in + established session + a supported tool =="
unset RALPH_RESUME_SESSION _RALPH_SESSION_ESTABLISHED
_should_resume claude && bad "resumed with continuity disabled" || ok "no resume when RALPH_RESUME_SESSION unset"
export RALPH_RESUME_SESSION=1
_should_resume claude && bad "resumed before any session established" || ok "no resume before the first call establishes a session"
export _RALPH_SESSION_ESTABLISHED=1
_should_resume claude && ok "resumes when opt-in + established (claude)" || bad "did not resume when it should"
_should_resume opencode && ok "resumes (opencode)" || bad "opencode did not resume"
_should_resume codex && bad "codex resumed (unsupported)" || ok "codex never resumes (keeps sandboxed fresh exec)"
_should_resume amp && bad "amp resumed (unsupported)" || ok "amp never resumes"
unset RALPH_RESUME_SESSION _RALPH_SESSION_ESTABLISHED

echo "== opencode: run --model, prompt-as-arg =="
_build_ai_cmd opencode "prov/mod"
[[ "${_AI_CMD[*]}" == "opencode run --format json --model prov/mod" ]] && ok "opencode run uses JSON events + --model" || bad "opencode cmd: ${_AI_CMD[*]}"
eq "opencode not stdin" 0 "$_AI_STDIN"
export RALPH_OPENCODE_JSON=0
_build_ai_cmd opencode "prov/mod"
[[ "${_AI_CMD[*]}" == "opencode run --model prov/mod" ]] && ok "opencode JSON mode can be disabled" || bad "opencode JSON opt-out failed: ${_AI_CMD[*]}"
unset RALPH_OPENCODE_JSON

echo "== opencode JSON output normalizes to plain agent text + provider evidence =="
if command -v jq >/dev/null 2>&1; then
    oj=$(mktemp -d); export RUN_DIR="$oj/run"
    mkdir -p "$RUN_DIR"
    printf '%s\n' \
      '{"type":"message.updated","sessionID":"sess_123","message":{"role":"assistant","content":[{"type":"text","text":"Implemented feature.\n<promise>COMPLETE</promise>"}]}}' \
      '{"type":"session.finished","sessionID":"sess_123","status":"completed"}' > "$oj/out"
    normalize_opencode_json_output "$oj/out" "$oj/log"
    grep -q '<promise>COMPLETE</promise>' "$oj/out" && ok "normalized opencode JSON preserves completion text" || bad "completion text missing after normalization: $(cat "$oj/out")"
    jq -e '.provider=="opencode" and .event_count==2 and (.sessions[0]=="sess_123")' "$RUN_DIR/providers/opencode.json" >/dev/null \
      && ok "opencode provider evidence persisted" || bad "opencode provider evidence missing/invalid"
    unset RUN_DIR
    rm -rf "$oj"
else
    ok "jq unavailable; skipped opencode JSON normalization fixture"
fi

echo "== agy: --model wired (agy DOES accept it), --print must stay LAST =="
_build_ai_cmd agy "Gemini 3.5 Flash (Low)"; eq "agy rc" 0 "$?"
[[ "${_AI_CMD[*]}" == *"--dangerously-skip-permissions"* ]] && ok "agy auto-approves" || bad "agy no skip-perms"
# Without --add-dir, agy headless writes to its OWN scratch workspace, not the project cwd.
# The value MUST be absolute (agy resolves a relative path against its own workspace).
[[ "${_AI_CMD[*]}" == *"--add-dir /"* ]] && ok "agy binds the project dir via an ABSOLUTE --add-dir" || bad "agy --add-dir not absolute: ${_AI_CMD[*]}"
( export PROJECT_DIR="$R"; _build_ai_cmd agy ""; [[ "${_AI_CMD[*]}" == *"--add-dir $R "* || "${_AI_CMD[*]}" == *"--add-dir $R" ]] ) && ok "agy --add-dir carries \$PROJECT_DIR" || bad "agy --add-dir did not honor PROJECT_DIR"
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

echo "== ollama: stdin-piped local API + ollama-agent executor =="
export RALPH_LOCAL_MODEL="qwen3:0.6b"
_build_ai_cmd ollama ""; eq "ollama rc" 0 "$?"
eq "ollama uses stdin" 1 "$_AI_STDIN"
[[ "${_AI_CMD[*]}" == *"RALPH_OLLAMA_MODEL=qwen3:0.6b"* && "${_AI_CMD[*]}" == *"/api/chat"* ]] && ok "ollama uses selected local model via API" || bad "ollama cmd: ${_AI_CMD[*]}"
_build_ai_cmd ollama-agent ""; eq "ollama-agent rc" 0 "$?"
eq "ollama-agent uses stdin" 1 "$_AI_STDIN"
[[ "${_AI_CMD[*]}" == *"python3"* && "${_AI_CMD[*]}" == *"ollama_agent.py"* && "${_AI_CMD[*]}" == *"--model qwen3:0.6b"* ]] && ok "ollama-agent invokes guarded Python executor" || bad "ollama-agent cmd: ${_AI_CMD[*]}"
unset RALPH_LOCAL_MODEL

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
for t in opencode claude amp agy codex ollama ollama-agent jules; do _ralph_is_valid_tool "$t" && ok "valid: $t" || bad "rejected valid tool: $t"; done
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


echo "== run_ai_tool watchdog: internal timeout kills a hung CLI even without coreutils timeout =="
wdir=$(mktemp -d); stub="$wdir/bin"; mkdir -p "$stub"
printf '#!/bin/bash\n(sleep 30) & wait\n' > "$stub/opencode"; chmod +x "$stub/opencode"
lf="$wdir/log"; of="$wdir/out"; : > "$lf"; : > "$of"
PATH="$stub:$PATH" RALPH_TOOL_TIMEOUT=1 PROJECT_DIR="$wdir" iteration=1 MAX_ITERATIONS=1
_timeout_bin() { echo ""; }
start_watchdog=$SECONDS
run_ai_tool opencode "" "prompt" "$lf" "$of"; watchdog_rc=$?
watchdog_elapsed=$((SECONDS - start_watchdog))
eq "hung tool returns timeout rc" 124 "$watchdog_rc"
[[ "$watchdog_elapsed" -lt 8 ]] && ok "watchdog returned promptly (${watchdog_elapsed}s)" || bad "watchdog took too long (${watchdog_elapsed}s)"
grep -q "exceeded RALPH_TOOL_TIMEOUT=1s" "$lf" && ok "timeout warning logged" || bad "timeout warning missing"
rm -rf "$wdir"

echo "== signal cleanup: TERM reaps provider process tree before exit =="
sdir=$(mktemp -d); sstub="$sdir/bin"; mkdir -p "$sstub" "$sdir/project"
cat > "$sstub/opencode" <<'SH'
#!/bin/bash
printf '%s\n' "$$" > "$PROVIDER_PID_FILE"
sleep 30 &
printf '%s\n' "$!" > "$PROVIDER_CHILD_PID_FILE"
wait
SH
chmod +x "$sstub/opencode"
bash -c '
    source "$1/lib/utils.sh"
    source "$1/lib/processes.sh"
    source "$1/lib/engine.sh"
    set +eu
    IFS=" "
    export PATH="$2/bin:$PATH"
    export PROVIDER_PID_FILE="$2/provider.pid"
    export PROVIDER_CHILD_PID_FILE="$2/provider-child.pid"
    export RALPH_TOOL_TIMEOUT=20
    export RALPH_TOOL_IDLE_TIMEOUT=0
    export RALPH_OPENCODE_JSON=0
    export PROJECT_DIR="$2/project"
    iteration=1
    MAX_ITERATIONS=1
    run_ai_tool opencode "" prompt "$2/log" "$2/out"
' _ "$R" "$sdir" >/dev/null 2>&1 &
runner_pid=$!
for _ in {1..50}; do
    [[ -s "$sdir/provider.pid" && -s "$sdir/provider-child.pid" ]] && break
    sleep 0.1
done
provider_pid=$(cat "$sdir/provider.pid" 2>/dev/null || true)
provider_child_pid=$(cat "$sdir/provider-child.pid" 2>/dev/null || true)
if valid_test_pid "$provider_pid" && valid_test_pid "$provider_child_pid"; then
    ok "TERM fixture recorded provider process tree"
else
    bad "TERM fixture did not record valid provider PIDs"
fi
kill -TERM "$runner_pid" 2>/dev/null || true
wait "$runner_pid"; signal_rc=$?
for _ in {1..30}; do
    if ! test_pid_alive "$provider_pid" && ! test_pid_alive "$provider_child_pid"; then
        break
    fi
    sleep 0.1
done
eq "TERM preserves conventional exit code" 143 "$signal_rc"
if test_pid_alive "$provider_pid"; then
    bad "provider survived Ralph TERM cleanup"
else
    ok "provider reaped on Ralph TERM"
fi
if test_pid_alive "$provider_child_pid"; then
    bad "provider descendant survived Ralph TERM cleanup"
else
    ok "provider descendant reaped on Ralph TERM"
fi
kill_test_pids "$provider_pid" "$provider_child_pid"
rm -rf "$sdir"
echo "== parent-death guardian: SIGKILL cannot orphan provider tree =="
kdir=$(mktemp -d); kstub="$kdir/bin"; mkdir -p "$kstub" "$kdir/project"
cat > "$kstub/opencode" <<'SH'
#!/bin/bash
printf '%s\n' "$$" > "$PROVIDER_PID_FILE"
sleep 30 &
printf '%s\n' "$!" > "$PROVIDER_CHILD_PID_FILE"
wait
SH
chmod +x "$kstub/opencode"
bash -c '
    source "$1/lib/utils.sh"
    source "$1/lib/processes.sh"
    source "$1/lib/engine.sh"
    set +eu
    IFS=" "
    export PATH="$2/bin:$PATH"
    export PROVIDER_PID_FILE="$2/provider.pid"
    export PROVIDER_CHILD_PID_FILE="$2/provider-child.pid"
    export RALPH_TOOL_TIMEOUT=20
    export RALPH_TOOL_IDLE_TIMEOUT=0
    export RALPH_OPENCODE_JSON=0
    export PROJECT_DIR="$2/project"
    iteration=1
    MAX_ITERATIONS=1
    exec 9>"$2/ralph.lock"
    flock -n 9 || exit 70
    run_ai_tool opencode "" prompt "$2/log" "$2/out"
' _ "$R" "$kdir" >/dev/null 2>&1 &
killed_runner_pid=$!
for _ in {1..50}; do
    [[ -s "$kdir/provider.pid" && -s "$kdir/provider-child.pid" ]] && break
    sleep 0.1
done
killed_provider_pid=$(cat "$kdir/provider.pid" 2>/dev/null || true)
killed_provider_child_pid=$(cat "$kdir/provider-child.pid" 2>/dev/null || true)
if valid_test_pid "$killed_provider_pid" && valid_test_pid "$killed_provider_child_pid"; then
    ok "SIGKILL fixture recorded provider process tree"
else
    bad "SIGKILL fixture did not record valid provider PIDs"
fi
sleep 0.3
mapfile -t killed_owned_pids < <(pgrep -P "$killed_runner_pid" 2>/dev/null || true)
kill -KILL "$killed_runner_pid" 2>/dev/null || true
wait "$killed_runner_pid"; killed_runner_rc=$?
lock_reacquired=false
for _ in {1..30}; do
    if ( flock -n 9 ) 9>"$kdir/ralph.lock"; then
        lock_reacquired=true
        break
    fi
    sleep 0.1
done
for _ in {1..50}; do
    owned_alive=0
    for owned_pid in "${killed_owned_pids[@]}"; do
        test_pid_alive "$owned_pid" && owned_alive=1
    done
    if ! test_pid_alive "$killed_provider_pid" &&
       ! test_pid_alive "$killed_provider_child_pid" &&
       [[ "$owned_alive" -eq 0 ]]; then
        break
    fi
    sleep 0.1
done
eq "SIGKILL preserves conventional exit code" 137 "$killed_runner_rc"
[[ "$lock_reacquired" == "true" ]] && ok "singleton lock released within recovery window" || bad "child retained singleton lock beyond recovery window"
if test_pid_alive "$killed_provider_pid"; then
    bad "provider survived Ralph SIGKILL"
else
    ok "guardian reaped provider after Ralph SIGKILL"
fi
if test_pid_alive "$killed_provider_child_pid"; then
    bad "provider descendant survived Ralph SIGKILL"
else
    ok "guardian reaped provider descendant after Ralph SIGKILL"
fi
owned_alive=0
for owned_pid in "${killed_owned_pids[@]}"; do
    test_pid_alive "$owned_pid" && owned_alive=1
done
[[ "$owned_alive" -eq 0 ]] && ok "guardian exited after SIGKILL cleanup" || bad "owned process survived SIGKILL cleanup"
kill_test_pids "$killed_provider_pid" "$killed_provider_child_pid" "${killed_owned_pids[@]}"
rm -rf "$kdir"
echo "== run_ai_tool quiescence: quiet-after-change provider is gracefully stopped =="
if command -v jq >/dev/null 2>&1; then
    qdir=$(mktemp -d); qstub="$qdir/bin"; mkdir -p "$qstub" "$qdir/proj"
    cat > "$qstub/opencode" <<'SH'
#!/bin/bash
printf 'implemented files, still parked\n'
printf '%s\n' '{"scripts":{"test":"node --test"}}' > "$PROJECT_DIR/package.json"
printf 'done\n' > "$PROJECT_DIR/result.txt"
sleep 30
SH
    chmod +x "$qstub/opencode"
    lf="$qdir/log"; of="$qdir/out"; : > "$lf"; : > "$of"
    export PATH="$qstub:$PATH"
    export RALPH_TOOL_TIMEOUT=20 RALPH_TOOL_IDLE_TIMEOUT=1 RALPH_TOOL_IDLE_MIN_RUNTIME=0 RALPH_TOOL_IDLE_PROBE_INTERVAL=1 PROJECT_DIR="$qdir/proj" RALPH_OPENCODE_JSON=0
    iteration=1; MAX_ITERATIONS=1
    start_quiet=$SECONDS
    run_ai_tool opencode "" "prompt" "$lf" "$of"; quiet_rc=$?
    quiet_elapsed=$((SECONDS - start_quiet))
    eq "quiet-after-change stop returns success" 0 "$quiet_rc"
    [[ "$quiet_elapsed" -lt 8 ]] && ok "quiescence returned promptly (${quiet_elapsed}s)" || bad "quiescence took too long (${quiet_elapsed}s)"
    grep -q "quiet after project progress" "$lf" && ok "quiescence warning logged" || bad "quiescence warning missing"
    unset RALPH_TOOL_TIMEOUT RALPH_TOOL_IDLE_TIMEOUT RALPH_TOOL_IDLE_MIN_RUNTIME RALPH_TOOL_IDLE_PROBE_INTERVAL RALPH_OPENCODE_JSON PROJECT_DIR
    rm -rf "$qdir"
else
    ok "jq unavailable; skipped quiescence fixture"
fi

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

echo "== resolve_agents_file: tool-native instructions file (claude=CLAUDE.md) + fallbacks =="
RD=$(mktemp -d); export PROJECT_DIR="$RD"; unset AGENTS_FILE
: > "$RD/AGENTS.md"; : > "$RD/CLAUDE.md"
eq "claude -> CLAUDE.md (native)"  "$RD/CLAUDE.md" "$(resolve_agents_file claude)"
eq "codex  -> AGENTS.md (native)"  "$RD/AGENTS.md" "$(resolve_agents_file codex)"
eq "agy    -> AGENTS.md (native)"  "$RD/AGENTS.md" "$(resolve_agents_file agy)"
rm -f "$RD/CLAUDE.md"
eq "claude falls back to AGENTS.md when no CLAUDE.md" "$RD/AGENTS.md" "$(resolve_agents_file claude)"
rm -f "$RD/AGENTS.md"; : > "$RD/CLAUDE.md"
eq "codex falls back to CLAUDE.md when no AGENTS.md"  "$RD/CLAUDE.md" "$(resolve_agents_file codex)"
: > "$RD/CUSTOM.md"; export AGENTS_FILE="CUSTOM.md"
eq "explicit AGENTS_FILE override wins"               "$RD/CUSTOM.md" "$(resolve_agents_file claude)"
# Strict: a set-but-missing AGENTS_FILE must NOT fall back, even if AGENTS.md/CLAUDE.md exist.
: > "$RD/AGENTS.md"; : > "$RD/CLAUDE.md"; export AGENTS_FILE="DOES_NOT_EXIST.md"
resolve_agents_file claude >/dev/null 2>&1 && bad "AGENTS_FILE override silently fell back" || ok "explicit AGENTS_FILE is strict (missing -> rc 1, no fallback)"
unset AGENTS_FILE; rm -f "$RD"/*.md
resolve_agents_file claude >/dev/null 2>&1 && bad "resolve_agents_file found a file when none exist" || ok "no instructions file -> rc 1"
unset PROJECT_DIR; rm -rf "$RD"

printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
