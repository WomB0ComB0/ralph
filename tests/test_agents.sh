#!/bin/bash
# Harness for lib/synapse.sh — the Ralph<->Synapse client + per-agent live test.
# Hermetic: `curl` and `sleep` are stubbed, so NO network and NO real Synapse is needed.
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export VERBOSE=false
# shellcheck disable=SC1090
source "$R/lib/utils.sh"
# shellcheck disable=SC1090
source "$R/lib/signals.sh"
# shellcheck disable=SC1090
source "$R/lib/synapse.sh"
set +eu

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (exp [$2] got [$3])"; fi; }

# --- stubs -------------------------------------------------------------------
# curl stub: emits "<body>\n<http_code>" like `curl -w '\n%{http_code}'`. Behaviour is
# driven by SYN_MODE / SYN_HEALTH and a call counter, keyed on the endpoint (last URL segment).
# curl runs inside $(...) (a subshell), so count calls via a file that survives the subshell.
SYN_CALL_LOG=$(mktemp)
curl() {
    echo x >> "$SYN_CALL_LOG"
    local url="${!#}" ep; ep="${url##*/}"
    case "${SYN_MODE:-}" in
        force401) printf 'unauthorized\n401'; return 0 ;;
        force429) printf 'slow down\n429'; return 0 ;;   # always retriable -> exercises retry/exhaust
    esac
    case "$ep" in
        health)
            [[ "${SYN_HEALTH:-ok}" == "bad" ]] && { printf 'down\n503'; return 0; }
            printf '{"status":"ok"}\n200' ;;
        context.upsert) printf '{"principal_id":"agent:x","status":"upserted"}\n200' ;;
        context.get)    printf '{"principal_id":"agent:x","active_projects":["livetest"],"data_classification":{"contains_pii":false,"special_category":false}}\n200' ;;
        retrieve)       printf '{"results":[],"trace_id":"t-abc"}\n200' ;;
        *)              printf '{}\n200' ;;
    esac
    return 0
}
sleep() { :; }   # make retry backoff instant

export SYNAPSE_URL="http://synapse.test:8080" SYNAPSE_TENANT="ralph-dev" SYNAPSE_RETRIES=2

echo "== config resolution defaults =="
eq "url"       "http://synapse.test:8080" "$(_syn_url)"
eq "tenant"    "ralph-dev"                "$(_syn_tenant)"
eq "principal default" "agent:ralph"      "$(_syn_principal)"
eq "principal override" "agent:claude"    "$(_syn_principal agent:claude)"

_calls() { wc -l < "$SYN_CALL_LOG" | tr -d ' '; }
echo "== _synapse_call status classification =="
SYN_MODE=""; : > "$SYN_CALL_LOG"
_synapse_call GET /health "agent:ralph" >/dev/null; eq "2xx -> rc 0" 0 "$?"
eq "2xx made exactly 1 call" 1 "$(_calls)"

SYN_MODE=force401; : > "$SYN_CALL_LOG"
_synapse_call GET /health "agent:ralph" >/dev/null 2>&1; eq "401 -> rc 41" 41 "$?"
eq "401 is NOT retried (1 call)" 1 "$(_calls)"

SYN_MODE=force429; : > "$SYN_CALL_LOG"
_synapse_call GET /health "agent:ralph" >/dev/null 2>&1; eq "429 exhausted -> rc 42" 42 "$?"
eq "429 retried RETRIES times (1+2 calls)" 3 "$(_calls)"
SYN_MODE=""

echo "== synapse_ping =="
synapse_ping >/dev/null 2>&1; eq "ping ok -> rc 0" 0 "$?"
SYN_HEALTH=bad; synapse_ping >/dev/null 2>&1; rc=$?; eq "ping down -> nonzero" 1 "$(( rc == 0 ? 0 : 1 ))"; SYN_HEALTH=ok

echo "== synapse_live_test happy path =="
out=$(synapse_live_test claude 2>&1); rc=$?
eq "live-test PASS -> rc 0" 0 "$rc"
[[ "$out" == *"[PASS] live-test claude OK"* ]] && ok "prints final PASS line" || bad "no final PASS: $out"
[[ "$out" == *"[PASS] context.get"* ]] && ok "context round-trip asserted" || bad "no context.get step: $out"

echo "== synapse_live_test failure records a signal + fails fast =="
_td=$(mktemp -d)
if command_exists jq; then
    ( export SIGNAL_DIR="$_td/signals" SIGNAL_ARCHIVE_DIR="$_td/signals/.archive" RUN_ID="test-1-1" SYN_HEALTH=bad
      out=$(synapse_live_test claude 2>&1); rc=$?
      [[ $rc -ne 0 ]] || exit 3
      [[ "$out" == *"[FAIL] health"* ]] || exit 4
      # a durable signal was recorded (dedup-by-theme json file present)
      [[ -n "$(find "$SIGNAL_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | head -1)" ]] || exit 5
      # and it did NOT proceed past the failing first step
      [[ "$out" != *"context.upsert"* ]] || exit 6
    )
    eq "fail -> nonzero, [FAIL] health, signal recorded, stops at step 1" 0 "$?"
else
    ok "SKIP signal assertion (jq unavailable)"
fi
rm -rf "$_td"

echo "== handle_agents_command test (multiple agents, space-split) =="
( export SYNAPSE_AGENTS="claude codex"
  handle_agents_command test >/dev/null 2>&1 ); eq "all agents pass -> rc 0" 0 "$?"
( export SYNAPSE_AGENTS="a,b,c"
  out=$(handle_agents_command list 2>&1)
  [[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" == "3" ]] ); eq "list splits comma-separated agents" 0 "$?"

rm -f "$SYN_CALL_LOG"
echo "----------------------------------"
echo "TOTAL: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
