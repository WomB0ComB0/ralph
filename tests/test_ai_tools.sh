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

echo "== opencode: run --model, prompt-as-arg =="
_build_ai_cmd opencode "prov/mod"
[[ "${_AI_CMD[*]}" == "opencode run --model prov/mod" ]] && ok "opencode run --model" || bad "opencode cmd: ${_AI_CMD[*]}"
eq "opencode not stdin" 0 "$_AI_STDIN"

echo "== agy: --print must be LAST (string-valued flag; prompt becomes its value) =="
_build_ai_cmd agy "ignored-model"; eq "agy rc" 0 "$?"
[[ "${_AI_CMD[*]}" == *"--dangerously-skip-permissions"* ]] && ok "agy auto-approves" || bad "agy no skip-perms"
# --print consumes the NEXT token as the prompt, so it MUST be the final flag in _AI_CMD;
# run_ai_tool appends "$prompt" after it -> `agy --dangerously-skip-permissions --print "<prompt>"`.
eq "agy --print is the LAST element" "--print" "${_AI_CMD[$((${#_AI_CMD[@]}-1))]}"
eq "agy not stdin" 0 "$_AI_STDIN"

echo "== amp: stdin-piped + allow-all =="
_build_ai_cmd amp "m"
eq "amp uses stdin" 1 "$_AI_STDIN"
[[ "${_AI_CMD[*]}" == *"--dangerously-allow-all"* ]] && ok "amp allow-all" || bad "amp flags: ${_AI_CMD[*]}"

echo "== unknown tool rejected =="
_build_ai_cmd bogus "m"; eq "unknown tool rc=1" 1 "$?"

echo "== per-tool env is subshell-scoped (must NOT leak to the parent) =="
unset CI ANTHROPIC_BASE_URL 2>/dev/null
( _apply_tool_env opencode ); [[ -z "${CI:-}" ]] && ok "opencode CI=true does not leak to parent" || bad "CI leaked to parent"
( _apply_tool_env claude ); [[ -z "${ANTHROPIC_BASE_URL:-}" ]] && ok "claude ANTHROPIC_BASE_URL does not leak" || bad "ANTHROPIC_BASE_URL leaked to parent"

printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
