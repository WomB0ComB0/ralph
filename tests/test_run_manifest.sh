#!/bin/bash
# Hermetic lifecycle tests for durable per-run manifests.
set -uo pipefail

R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "$R/lib/utils.sh"
# shellcheck disable=SC1090
source "$R/lib/run_manifest.sh"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL: %s\n' "$1"; }
eq() {
    if [[ "$2" == "$3" ]]; then
        ok "$1"
    else
        bad "$1 (expected [$2], got [$3])"
    fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export PROJECT_DIR="$TMP/project"
export _RALPH_DIR="$PROJECT_DIR/.ralph"
export STATE_DIR="$_RALPH_DIR/state"
export TOOL=opencode
export SELECTED_MODEL=local/test
export MAX_ITERATIONS=12
export RALPH_MAX_RUN_TOKENS=5000
export RALPH_MAX_RUN_SECONDS=600
export RALPH_MAX_LAZY_STREAK=4
export UNATTENDED=true
export SANDBOX_MODE=false
export JULES_API_KEY=manifest-must-not-leak-this
mkdir -p "$PROJECT_DIR"

echo "== initialization allowlist and permissions =="
export RUN_ID=run-one
export RUN_DIR="$_RALPH_DIR/runs/$RUN_ID"
init_run_manifest
manifest=$(run_manifest_file)
jq empty "$manifest" 2>/dev/null && ok "initial manifest is valid JSON" || bad "initial manifest is invalid"
eq "initial status" initializing "$(jq -r '.status' "$manifest")"
eq "schema version" 1 "$(jq -r '.schema_version' "$manifest")"
eq "tool recorded" opencode "$(jq -r '.execution.tool' "$manifest")"
eq "model recorded" local/test "$(jq -r '.execution.model' "$manifest")"
eq "unattended mode recorded" true "$(jq -r '.execution.unattended' "$manifest")"
eq "token limit recorded" 5000 "$(jq -r '.limits.max_tokens' "$manifest")"
eq "last run pointer recorded" run-one "$(cat "$STATE_DIR/last-run-id")"
eq "manifest permissions" 600 "$(stat -c '%a' "$manifest")"
if grep -q 'manifest-must-not-leak-this' "$manifest"; then
    bad "environment secret leaked into manifest"
else
    ok "environment secrets are excluded"
fi

echo "== heartbeat and explicit completion =="
export RUN_TOKENS_TOTAL=321
export LAZY_STREAK=2
export LAST_VERIFY_OK=true
export _RALPH_ACTIVE_MODEL=local/fallback
export _RALPH_RESUME_CHECKPOINT=4
run_manifest_heartbeat provider_execution 5 1
eq "heartbeat promotes status to running" running "$(jq -r '.status' "$manifest")"
eq "heartbeat phase recorded" provider_execution "$(jq -r '.phase' "$manifest")"
eq "heartbeat iteration recorded" 5 "$(jq -r '.current_iteration' "$manifest")"
eq "active fallback model recorded" local/fallback "$(jq -r '.execution.model' "$manifest")"
eq "token usage recorded" 321 "$(jq -r '.progress.tokens_total' "$manifest")"
eq "verification state recorded" true "$(jq -r '.progress.last_verify_ok' "$manifest")"
set_run_outcome completed completion_signal
finalize_run_manifest 0
eq "completion status recorded" completed "$(jq -r '.status' "$manifest")"
eq "completion reason recorded" completion_signal "$(jq -r '.reason' "$manifest")"
eq "completion exit code recorded" 0 "$(jq -r '.exit_code' "$manifest")"
eq "completion is a clean exit" true "$(jq -r '.clean_exit' "$manifest")"
[[ "$(jq -r '.finished_at' "$manifest")" != null ]] && ok "completion timestamp recorded" || bad "completion timestamp missing"
before=$(sha256sum "$manifest" | awk '{print $1}')
finalize_run_manifest 9
after=$(sha256sum "$manifest" | awk '{print $1}')
eq "finalization is idempotent" "$before" "$after"

echo "== stale run reconciliation and resume lineage =="
export RUN_ID=run-stale
export RUN_DIR="$_RALPH_DIR/runs/$RUN_ID"
unset _RALPH_ACTIVE_MODEL
export RESUME_FLAG=false
init_run_manifest
stale_manifest=$(run_manifest_file)
run_manifest_heartbeat provider_execution 3 1
_RALPH_RUN_ACTIVE=0

export RUN_ID=run-resume
export RUN_DIR="$_RALPH_DIR/runs/$RUN_ID"
export RESUME_FLAG=true
init_run_manifest
resume_manifest=$(run_manifest_file)
eq "stale active run becomes interrupted" interrupted "$(jq -r '.status' "$stale_manifest")"
eq "stale run has unclean reason" unclean_exit_detected "$(jq -r '.reason' "$stale_manifest")"
eq "stale run is not a clean exit" false "$(jq -r '.clean_exit' "$stale_manifest")"
eq "stale run names recovery run" run-resume "$(jq -r '.recovered_by_run_id' "$stale_manifest")"
eq "resume requested flag recorded" true "$(jq -r '.resume.requested' "$resume_manifest")"
eq "resume predecessor recorded" run-stale "$(jq -r '.resume.previous_run_id' "$resume_manifest")"
export _RALPH_RESUME_CHECKPOINT=7
run_manifest_heartbeat ready 7 1
eq "resume checkpoint recorded" 7 "$(jq -r '.resume.checkpoint_iteration' "$resume_manifest")"
set_run_outcome paused single_iteration
finalize_run_manifest 0
eq "scheduler pause is distinct" paused "$(jq -r '.status' "$resume_manifest")"

echo "== EXIT trap classifies unexpected failures =="
unexpected_root="$TMP/unexpected"
bash -c '
    source "$1/lib/utils.sh"
    source "$1/lib/run_manifest.sh"
    PROJECT_DIR="$2/project"
    _RALPH_DIR="$PROJECT_DIR/.ralph"
    STATE_DIR="$_RALPH_DIR/state"
    RUN_ID=run-unexpected
    RUN_DIR="$_RALPH_DIR/runs/$RUN_ID"
    TOOL=opencode
    SELECTED_MODEL=local/test
    MAX_ITERATIONS=2
    mkdir -p "$PROJECT_DIR"
    init_run_manifest
    run_manifest_heartbeat provider_execution 2 1
    exit 7
' _ "$R" "$unexpected_root" >/dev/null 2>&1
rc=$?
eq "unexpected process exit code preserved" 7 "$rc"
unexpected_manifest="$unexpected_root/project/.ralph/runs/run-unexpected/run.json"
eq "unexpected exit status" failed "$(jq -r '.status' "$unexpected_manifest")"
eq "unexpected exit reason" unexpected_exit "$(jq -r '.reason' "$unexpected_manifest")"
eq "unexpected exit evidence code" 7 "$(jq -r '.exit_code' "$unexpected_manifest")"

echo "== HUP, INT, and TERM retain conventional exit codes =="
for spec in "HUP:129:signal_hup" "INT:130:signal_int" "TERM:143:signal_term"; do
    IFS=: read -r signal expected reason <<<"$spec"
    signal_root="$TMP/signal-$signal"
    bash -c '
        source "$1/lib/utils.sh"
        source "$1/lib/run_manifest.sh"
        PROJECT_DIR="$2/project"
        _RALPH_DIR="$PROJECT_DIR/.ralph"
        STATE_DIR="$_RALPH_DIR/state"
        RUN_ID="run-$3"
        RUN_DIR="$_RALPH_DIR/runs/$RUN_ID"
        TOOL=opencode
        SELECTED_MODEL=local/test
        MAX_ITERATIONS=2
        mkdir -p "$PROJECT_DIR"
        init_run_manifest
        run_manifest_heartbeat provider_execution 1 1
        kill -s "$3" "$$"
        sleep 1
    ' _ "$R" "$signal_root" "$signal" >/dev/null 2>&1
    rc=$?
    signal_manifest="$signal_root/project/.ralph/runs/run-$signal/run.json"
    eq "$signal exit code preserved" "$expected" "$rc"
    eq "$signal status interrupted" interrupted "$(jq -r '.status' "$signal_manifest")"
    eq "$signal reason recorded" "$reason" "$(jq -r '.reason' "$signal_manifest")"
done

echo "== validation and atomic-write hygiene =="
if set_run_outcome nonsense invalid_reason; then
    bad "invalid terminal status accepted"
else
    ok "invalid terminal status rejected"
fi
if find "$TMP" -name '.run.json.tmp.*' -print -quit | grep -q .; then
    bad "temporary manifest file left behind"
else
    ok "atomic writes leave no temporary files"
fi

printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
