#!/bin/bash
# TDD harness for smart model management: failure classification, model fallback chain,
# local-first preference, and graceful degradation down the chain on capacity failures.
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export VERBOSE=false
# shellcheck disable=SC1090
source "$R/lib/utils.sh"
source "$R/lib/engine.sh"
set +eu
IFS=' '

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (exp [$2] got [$3])"; fi; }

# Isolate env so host config can't perturb the chain.
unset RALPH_MODEL_FALLBACKS RALPH_LOCAL_MODEL RALPH_PREFER_LOCAL SELECTED_MODEL SELECTED_MODEL_SOURCE

echo "== classify_tool_failure: capacity vs auth vs other =="
eq "HTTP 429 -> rate_limit"          "rate_limit" "$(classify_tool_failure 'Error: HTTP 429 Too Many Requests' 1)"
eq "'rate limit' text -> rate_limit" "rate_limit" "$(classify_tool_failure 'You have hit the rate limit, slow down' 1)"
eq "overloaded/529 -> overloaded"    "overloaded" "$(classify_tool_failure 'Error 529: Overloaded' 1)"
eq "quota -> quota"                  "quota"      "$(classify_tool_failure 'You exceeded your current quota, please check billing' 1)"
eq "out of credits -> quota"         "quota"      "$(classify_tool_failure 'insufficient_quota: out of credits' 1)"
eq "context length -> quota"         "quota"      "$(classify_tool_failure 'This model maximum context length is 8192 tokens' 1)"
eq "unauthorized text -> auth"       "auth"       "$(classify_tool_failure '401 Unauthorized: invalid api key' 1)"
eq "bare '401' number alone -> other (no false auth-stop)" "other" "$(classify_tool_failure 'see line 401 of the source' 1)"
eq "exit 124 -> timeout"             "timeout"    "$(classify_tool_failure '' 124)"
eq "generic -> other"               "other"      "$(classify_tool_failure 'Segmentation fault somewhere' 1)"

echo "== preferred_local_model: opencode-only, RALPH_LOCAL_MODEL, opt-out =="
export RALPH_LOCAL_MODEL="ollama/qwen2.5-coder"
eq "opencode + RALPH_LOCAL_MODEL -> that model" "ollama/qwen2.5-coder" "$(preferred_local_model opencode)"
preferred_local_model claude >/dev/null && bad "local preferred for claude (not a router)" || ok "non-opencode tool -> no local preference"
export RALPH_PREFER_LOCAL=0
preferred_local_model opencode >/dev/null && bad "local used while RALPH_PREFER_LOCAL=0" || ok "RALPH_PREFER_LOCAL=0 disables local-first"
unset RALPH_PREFER_LOCAL RALPH_LOCAL_MODEL

echo "== build_model_chain: primary + fallbacks, local-first, dedup, default==1 =="
# default (no config) -> single entry (behavior unchanged)
chain=$(build_model_chain claude engineer | paste -sd'|' -)
eq "claude default chain is single (sonnet)" "sonnet" "$chain"
# explicit fallbacks appended (trimmed)
export RALPH_MODEL_FALLBACKS="sonnet , haiku"
chain=$(build_model_chain claude planner | paste -sd'|' -)
eq "pinned-by-role opus + fallbacks (trimmed)" "opus|sonnet|haiku" "$chain"
unset RALPH_MODEL_FALLBACKS
# user-pinned model wins as primary, with fallbacks after
export SELECTED_MODEL="my/pinned" SELECTED_MODEL_SOURCE="config" RALPH_MODEL_FALLBACKS="a/b,c/d"
chain=$(build_model_chain opencode engineer | paste -sd'|' -)
eq "pinned primary + fallbacks" "my/pinned|a/b|c/d" "$chain"
unset SELECTED_MODEL SELECTED_MODEL_SOURCE RALPH_MODEL_FALLBACKS
# local-first: opencode + RALPH_LOCAL_MODEL, no pin -> local is the head
export RALPH_LOCAL_MODEL="ollama/local-x" RALPH_MODEL_FALLBACKS="cloud/y"
chain=$(build_model_chain opencode engineer | head -1)
eq "local-first head for opencode" "ollama/local-x" "$chain"
unset RALPH_LOCAL_MODEL RALPH_MODEL_FALLBACKS
# dedup consecutive duplicates
export SELECTED_MODEL="dup" SELECTED_MODEL_SOURCE="config" RALPH_MODEL_FALLBACKS="dup,other"
eq "consecutive dup collapsed" "dup|other" "$(build_model_chain opencode engineer | paste -sd'|' -)"
unset SELECTED_MODEL SELECTED_MODEL_SOURCE RALPH_MODEL_FALLBACKS
# empty entries (trailing/double comma) must NOT become empty model attempts
export SELECTED_MODEL="p" SELECTED_MODEL_SOURCE="config" RALPH_MODEL_FALLBACKS="a,,b,"
eq "empty fallback entries dropped" "p|a|b" "$(build_model_chain opencode engineer | paste -sd'|' -)"
unset SELECTED_MODEL SELECTED_MODEL_SOURCE RALPH_MODEL_FALLBACKS

echo "== run_ai_with_fallback: graceful degradation on capacity failure (stubbed tool) =="
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export AI_RETRY_ATTEMPTS=1 AI_RETRY_BASE_DELAY=0   # no slow backoff in tests
TRIED="$TMP/tried"
# Stub: model-a is "rate limited" — error written to the LOG (stderr), $out empty, like a real
# CLI. This guards the critical path: classify must read the log, not just the stdout file.
run_ai_tool() { echo "$2" >> "$TRIED"; if [[ "$2" == "model-a" ]]; then echo '429 rate limit exceeded' >> "$4"; : > "$5"; return 1; fi; echo "done by $2" > "$5"; return 0; }
: > "$TRIED"; : > "$TMP/log"; export SELECTED_MODEL="model-a" SELECTED_MODEL_SOURCE="config" RALPH_MODEL_FALLBACKS="model-b"
run_ai_with_fallback opencode engineer "p" "$TMP/log" "$TMP/out"; rc=$?
eq "rate-limited primary -> overall success via fallback" 0 "$rc"
eq "both models attempted in order" "model-a model-b" "$(paste -sd' ' "$TRIED")"
eq "active model = the fallback that worked" "model-b" "$_RALPH_ACTIVE_MODEL"
eq "SELECTED_MODEL NOT mutated (non-sticky across iterations)" "model-a" "$SELECTED_MODEL"
grep -q 'done by model-b' "$TMP/out" && ok "output is from the fallback model" || bad "output not from fallback"

# A NON-capacity failure must NOT burn the chain.
run_ai_tool() { echo "$2" >> "$TRIED"; echo 'fatal: nonsense bug' > "$5"; return 1; }
: > "$TRIED"; : > "$TMP/log"; export SELECTED_MODEL="model-a" SELECTED_MODEL_SOURCE="config" RALPH_MODEL_FALLBACKS="model-b"
run_ai_with_fallback opencode engineer "p" "$TMP/log" "$TMP/out"; rc=$?
[[ $rc -ne 0 ]] && ok "non-capacity failure returns non-zero" || bad "non-capacity failure masked as success"
eq "non-capacity failure does NOT try the fallback" "model-a" "$(paste -sd' ' "$TRIED")"

# Happy path: primary succeeds -> fallback never tried.
run_ai_tool() { echo "$2" >> "$TRIED"; echo "ok $2" > "$5"; return 0; }
: > "$TRIED"; : > "$TMP/log"; export SELECTED_MODEL="model-a" SELECTED_MODEL_SOURCE="config" RALPH_MODEL_FALLBACKS="model-b"
run_ai_with_fallback opencode engineer "p" "$TMP/log" "$TMP/out"; rc=$?
eq "primary success rc" 0 "$rc"
eq "fallback NOT tried when primary succeeds" "model-a" "$(paste -sd' ' "$TRIED")"

printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
