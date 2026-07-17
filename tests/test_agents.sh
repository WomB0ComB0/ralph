#!/bin/bash
# Harness for lib/synapse.sh — the Ralph<->Synapse client + per-agent live test.
# Hermetic: `curl` and `sleep` are stubbed, so NO network and NO real Synapse is needed.
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export VERBOSE=false
# shellcheck disable=SC1090
source "$R/lib/utils.sh"
# shellcheck disable=SC1090
source "$R/lib/engine.sh"    # _build_ai_cmd / _apply_tool_env / _timeout_bin for the agent CLI probe
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
    local url="${!#}" ep; ep="${url##*/}"
    echo "$ep" >> "$SYN_CALL_LOG"
    case "${SYN_MODE:-}" in
        force401) printf 'unauthorized\n401'; return 0 ;;
        force429) printf 'slow down\n429'; return 0 ;;   # always retriable -> exercises retry/exhaust
    esac
    case "$ep" in
        health)
            [[ "${SYN_HEALTH:-ok}" == "bad" ]] && { printf 'down\n503'; return 0; }
            if [[ "${SYN_HEALTH:-ok}" == "flaky" ]]; then
                local health_calls; health_calls=$(grep -c '^health$' "$SYN_CALL_LOG" 2>/dev/null || true)
                [[ "$health_calls" -eq 1 ]] && { printf '\n000'; return 0; }
            fi
            printf '{"status":"ok"}\n200' ;;
        context.upsert) printf '{"principal_id":"agent:x","status":"upserted"}\n200' ;;
        context.get)    printf '{"principal_id":"agent:x","active_projects":["livetest"],"data_classification":{"contains_pii":false,"special_category":false}}\n200' ;;
        retrieve)       printf '{"results":[],"trace_id":"t-abc"}\n200' ;;
        *)              printf '{}\n200' ;;
    esac
    return 0
}
sleep() { :; }   # make retry backoff instant

# Stub the agent CLIs as shell functions so command_exists sees them AND the exec path calls the stub
# (default echoes PONG). AGENT_PROBE_TIMEOUT=0 drops the `timeout` wrapper so a *function* stub is reachable.
claude()   { echo "PONG"; }
codex()    { echo "PONG"; }
opencode() { echo "PONG"; }
export AGENT_PROBE_TIMEOUT=0

# Keep any recorded signals in a throwaway dir — never litter the repo's .ralph/ when run standalone.
export SIGNAL_DIR="$(mktemp -d)/signals" SIGNAL_ARCHIVE_DIR="$SIGNAL_DIR/.archive" RUN_ID="test-agents-1"

export SYNAPSE_URL="http://synapse.test:8080" SYNAPSE_TENANT="ralph-dev" SYNAPSE_RETRIES=2

echo "== config resolution defaults =="
eq "url"       "http://synapse.test:8080" "$(_syn_url)"
eq "tenant"    "ralph-dev"                "$(_syn_tenant)"
eq "principal default" "agent:ralph"      "$(_syn_principal)"
eq "principal override" "agent:claude"    "$(_syn_principal agent:claude)"


echo "== synapse auth boundary guard =="
unset BIND_ADDR SYNAPSE_BIND_ADDR AUTH_JWT_SECRET AUTH_JWT_PUBLIC_KEY AUTH_JWKS_URL SYNAPSE_TOKEN
synapse_auth_guard >/dev/null 2>&1; eq "default loopback bind passes without JWT" 0 "$?"
export BIND_ADDR=0.0.0.0
synapse_auth_guard >/dev/null 2>"$SYN_CALL_LOG"; rc=$?
eq "non-loopback bind without JWT fails" 1 "$(( rc == 0 ? 0 : 1 ))"
grep -q 'without verified JWT auth' "$SYN_CALL_LOG" && ok "non-loopback failure explains JWT requirement" || bad "missing JWT guard message: $(cat "$SYN_CALL_LOG")"
AUTH_JWT_SECRET=dev-secret synapse_auth_guard >/dev/null 2>&1; eq "non-loopback bind with JWT secret passes" 0 "$?"
unset AUTH_JWT_SECRET
AUTH_JWKS_URL=https://issuer.example/jwks.json synapse_auth_guard >/dev/null 2>&1; eq "non-loopback bind with JWKS passes" 0 "$?"
unset AUTH_JWKS_URL BIND_ADDR
SYNAPSE_TOKEN=caller.jwt.token _syn_headers "agent:ralph"
printf '%s\n' "${_SYN_HDR[@]}" | grep -q 'Authorization: Bearer caller.jwt.token' && ok "Ralph caller sends bearer token when SYNAPSE_TOKEN is set" || bad "missing Authorization header: ${_SYN_HDR[*]}"
unset SYNAPSE_TOKEN

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


echo "== main prompt Synapse grounding hook =="
SYNAPSE_ENABLED=0
synapse_ground() { printf 'SHOULD_NOT_APPEAR'; }
grounded=$(synapse_grounding_context "agent instructions")
eq "disabled grounding returns empty" "" "$grounded"
unset -f synapse_ground

SYNAPSE_ENABLED=1 RALPH_ROLE=engineer PROJECT_DIR="/tmp/ralph-demo" SYNAPSE_PRINCIPAL="agent:engineer"
QUERY_FILE=$(mktemp); PRINCIPAL_FILE=$(mktemp)
synapse_ground() {
    printf '%s' "$1" > "$QUERY_FILE"
    printf '%s' "$2" > "$PRINCIPAL_FILE"
    printf '<synapse_context>\n- (memory://1) prior decision\n</synapse_context>\n'
}
grounded=$(synapse_grounding_context "follow AGENTS.md")
printf '%s' "$grounded" | grep -q '<synapse_context>' && ok "enabled grounding returns Synapse context block" || bad "missing Synapse context: $grounded"
grep -q "project 'ralph-demo'" "$QUERY_FILE" && ok "grounding query includes project" || bad "grounding query missing project: $(cat "$QUERY_FILE")"
grep -q "role 'engineer'" "$QUERY_FILE" && ok "grounding query includes role" || bad "grounding query missing role: $(cat "$QUERY_FILE")"
eq "grounding passes configured principal" "agent:engineer" "$(cat "$PRINCIPAL_FILE")"
prompt_with_grounding=$(generate_system_prompt "user" "plan" "prd" "diagram" "" "" "changes" "resources" "base-context
$grounded" "quality" "project instructions")
printf '%s' "$prompt_with_grounding" | grep -q '<synapse_context>' && ok "generated prompt can carry Synapse context" || bad "prompt omitted Synapse context"
unset -f synapse_ground

synapse_ground() { printf 'network unavailable\n' >&2; return 42; }
err=$(mktemp)
grounded=$(synapse_grounding_context "agent instructions" 2>"$err"); rc=$?
eq "failed grounding remains fail-open" "0" "$rc"
eq "failed grounding returns empty" "" "$grounded"
grep -q 'network unavailable' "$err" && ok "failed grounding logs underlying Synapse error" || bad "missing failure log: $(cat "$err")"
unset -f synapse_ground
unset SYNAPSE_ENABLED SYNAPSE_PRINCIPAL RALPH_ROLE PROJECT_DIR QUERY_FILE PRINCIPAL_FILE

echo "== synapse_live_test happy path =="
out=$(synapse_live_test claude 2>&1); rc=$?
eq "live-test PASS -> rc 0" 0 "$rc"
[[ "$out" == *"[PASS] live-test claude OK"* ]] && ok "prints final PASS line" || bad "no final PASS: $out"
[[ "$out" == *"[PASS] context.get"* ]] && ok "context round-trip asserted" || bad "no context.get step: $out"

echo "== synapse_live_test retries transient health failures =="
: > "$SYN_CALL_LOG"
SYN_HEALTH=flaky
out=$(synapse_live_test claude 2>&1); rc=$?
eq "flaky health recovers -> rc 0" 0 "$rc"
eq "health retried once then continued" 2 "$(grep -c '^health$' "$SYN_CALL_LOG" 2>/dev/null || true)"
[[ "$out" == *"[PASS] live-test claude OK"* ]] && ok "flaky health prints final PASS line" || bad "flaky health did not pass: $out"
SYN_HEALTH=ok

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

echo "== agent_cli_probe (the CLI itself) =="
st=$(agent_cli_probe claude installed); rc=$?
eq "installed present -> rc 0" 0 "$rc"; eq "status installed" "installed" "$st"
st=$(agent_cli_probe __nope_tool__ installed); rc=$?
eq "missing CLI -> rc 20" 20 "$rc"; eq "status not-installed" "not-installed" "$st"
_probe_status=$(mktemp)
agent_cli_probe claude live > "$_probe_status"; rc=$?; st=$(cat "$_probe_status"); rm -f "$_probe_status"
eq "live probe (stub echoes PONG) -> rc 0" 0 "$rc"; eq "live status ok" "ok" "$st"
cmd_join=$(printf " %s " "${_AI_CMD[@]}")
[[ "$cmd_join" == *" claude "* && "$cmd_join" == *" -p "* && "$cmd_join" == *" --dangerously-skip-permissions "* ]] && ok "claude live probe uses Ralph headless Claude command" || bad "claude live probe command mismatch: $cmd_join"
st=$( claude() { echo ""; };  agent_cli_probe claude live ); eq "live empty output -> empty-output" "empty-output" "$st"
st=$( claude() { return 3; }; agent_cli_probe claude live ); eq "live non-zero exit -> exit:3" "exit:3" "$st"

echo "== agent_live_test (CLI then Synapse; CLI failure short-circuits) =="
: > "$SYN_CALL_LOG"
agent_live_test __nope_tool__ installed >/dev/null 2>&1; eq "missing CLI -> rc 1" 1 "$?"
eq "CLI fail short-circuits (Synapse NOT called)" 0 "$(_calls)"
out=$(agent_live_test claude live 2>&1); rc=$?
eq "cli ok + synapse ok -> rc 0" 0 "$rc"
[[ "$out" == *"[PASS] cli:claude"* && "$out" == *"[PASS] live-test claude OK"* ]] && ok "runs BOTH cli + synapse legs" || bad "missing a leg: $out"

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
