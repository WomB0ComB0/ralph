#!/bin/bash
# TDD harness for dynamic, live-listing model resolution (lib/engine.sh).
#   _pick_latest_model role list_text   -> newest model for the role from a live list
#   resolve_model_for_tool tool role    -> tool-aware (agy/opencode live, claude/amp aliases)
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export VERBOSE=false
# shellcheck disable=SC1090
source "$R/lib/utils.sh"
source "$R/lib/engine.sh"
set +eu

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (exp [$2] got [$3])"; fi; }

# Real `agy models` output captured live (Antigravity = Google's current CLI).
AGY='Gemini 3.5 Flash (Medium)
Gemini 3.5 Flash (High)
Gemini 3.5 Flash (Low)
Gemini 3.1 Pro (Low)
Gemini 3.1 Pro (High)
Claude Sonnet 4.6 (Thinking)
Claude Opus 4.6 (Thinking)
GPT-OSS 120B (Medium)'

echo "== _pick_latest_model: newest per role from the agy list =="
eq "planner -> highest-version reasoning model" "Claude Opus 4.6 (Thinking)" "$(_pick_latest_model planner "$AGY")"
eq "tester -> a low/efficient flash tier"       "Gemini 3.5 Flash (Low)"     "$(_pick_latest_model tester "$AGY")"
eng=$(_pick_latest_model engineer "$AGY")
[[ "$eng" == "Claude Sonnet 4.6 (Thinking)" ]] && ok "engineer -> newest capable (Sonnet 4.6)" || bad "engineer got [$eng]"
[[ "$(_pick_latest_model planner "$AGY")" != *"GPT-OSS"* ]] && ok "120B param count does not masquerade as a version" || bad "GPT-OSS leaked"
eq "empty list -> empty" "" "$(_pick_latest_model engineer "")"

echo "== resolve_model_for_tool: claude/amp use latest-resolving aliases =="
eq "claude planner -> opus alias"    opus   "$(resolve_model_for_tool claude planner)"
eq "claude engineer -> sonnet alias" sonnet "$(resolve_model_for_tool claude engineer)"
eq "amp tester -> sonnet alias"      sonnet "$(resolve_model_for_tool amp tester)"
[[ "$(resolve_model_for_tool claude planner)" != *"2024"* && "$(resolve_model_for_tool claude planner)" != *"3-5"* ]] && ok "claude no longer pins a stale dated model" || bad "claude still pinned"

echo "== resolve_model_for_tool agy: live-lists via 'agy models' (stubbed) =="
STUB=$(mktemp -d); printf '#!/bin/bash\n[[ "$1" == models ]] && printf "%%s\\n" "Gemini 3.5 Flash (Low)" "Claude Opus 4.6 (Thinking)"\n' > "$STUB/agy"; chmod +x "$STUB/agy"
got=$(PATH="$STUB:$PATH" resolve_model_for_tool agy planner)
[[ "$got" == "Claude Opus 4.6 (Thinking)" ]] && ok "agy planner resolves newest from 'agy models'" || bad "agy resolve got [$got]"
rm -rf "$STUB"

echo "== param-count tokens (NNb) must not masquerade as a version =="
PARAM='claude-sonnet-4-5
qwen-72b-coder-2.5'
eq "72b param count does not beat sonnet-4-5" "claude-sonnet-4-5" "$(_pick_latest_model engineer "$PARAM")"

echo "== validate_model_availability accepts claude/amp tier aliases =="
validate_model_availability "sonnet" claude >/dev/null 2>&1 && ok "sonnet alias validates for claude" || bad "sonnet alias rejected by validator"
validate_model_availability "opus" amp >/dev/null 2>&1 && ok "opus alias validates for amp" || bad "opus alias rejected by validator"

printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
