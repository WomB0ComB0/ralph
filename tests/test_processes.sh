#!/bin/bash
# Hermetic tests for owned-process cleanup and allowlisted shutdown evidence.
set -uo pipefail

R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "$R/lib/processes.sh"

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
TERM_PID=""
KILL_PID=""
DISCOVERY_PID=""
IDENTITY_PID=""
DESC_ROOT_PID=""
DESC_CHILD_PID=""
OWNER_PID=""
GUARD_CHILD_PID=""
GUARDIAN_PID=""
BOUNDARY_PID=""

valid_pid() {
    local pid="${1:-}"
    [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 1 ))
}

launch_supervised_fixture() {
    local log_file="$1" output_file="$2" supervisor_path state_file ack_file
    shift 2
    prepare_supervised_process || return 1
    state_file="$_RALPH_BOUNDARY_STATE_FILE"
    ack_file="$_RALPH_BOUNDARY_ACK_FILE"
    supervisor_path=$(_ralph_process_supervisor_path) || return 1
    python3 "$supervisor_path" \
        --state-file "$state_file" \
        --ack-file "$ack_file" \
        --log-file "$log_file" \
        --stdout-file "$output_file" \
        -- "$@" &
    BOUNDARY_PID=$!
    register_supervised_process "$BOUNDARY_PID" provider "$state_file" "$ack_file"
}

cleanup() {
    local pid
    terminate_registered_processes 1 >/dev/null 2>&1 || true
    for pid in "$TERM_PID" "$KILL_PID" "$DISCOVERY_PID" "$IDENTITY_PID" "$DESC_ROOT_PID" "$DESC_CHILD_PID" "$OWNER_PID" "$GUARD_CHILD_PID" "$GUARDIAN_PID" "$BOUNDARY_PID"; do
        if valid_pid "$pid"; then
            _ralph_terminate_process_tree KILL "$pid"
        fi
    done
    rm -rf "$TMP"
}
trap cleanup EXIT

missing=false
for function_name in _ralph_record_process_cleanup_event terminate_owned_process; do
    if ! declare -F "$function_name" >/dev/null 2>&1; then
        bad "required process evidence function exists: $function_name"
        missing=true
    fi
done
if [[ "$missing" == "true" ]]; then
    printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
    exit 1
fi

echo "== procfs child discovery fallback =="
mkdir -p "$TMP/empty-path"
sleep 30 &
DISCOVERY_PID=$!
saved_path="$PATH"
PATH="$TMP/empty-path"
discovered=$(_ralph_child_pids "$$" 2>/dev/null || true)
PATH="$saved_path"
discovery_found=0
while IFS= read -r discovered_pid; do
    if [[ "$discovered_pid" == "$DISCOVERY_PID" ]]; then
        discovery_found=1
        break
    fi
done <<<"$discovered"
if [[ "$discovery_found" -eq 1 ]]; then
    ok "procfs discovers children without pgrep or ps"
else
    bad "procfs child discovery fallback missed owned process"
fi
kill -KILL "$DISCOVERY_PID" 2>/dev/null || true
wait "$DISCOVERY_PID" 2>/dev/null || true
DISCOVERY_PID=""

echo "== supervised process boundary protocol =="
export RUN_DIR="$TMP/supervisor-normal"
mkdir -p "$RUN_DIR"
prepare_supervised_process
normal_state="$_RALPH_BOUNDARY_STATE_FILE"
normal_ack="$_RALPH_BOUNDARY_ACK_FILE"
normal_log="$RUN_DIR/provider.log"
eq "boundary handshake directory" "$RUN_DIR/process-boundaries" "$(dirname "$normal_state")"
normal_output="$RUN_DIR/provider.out"
supervisor_path=$(_ralph_process_supervisor_path)
python3 "$supervisor_path" \
    --state-file "$normal_state" \
    --ack-file "$normal_ack" \
    --log-file "$normal_log" \
    --stdout-file "$normal_output" \
    -- bash -c 'printf "answer\n"; printf "diagnostic\n" >&2; exit 7' &
BOUNDARY_PID=$!
for _ in {1..250}; do
    [[ -s "$normal_state" ]] && break
    sleep 0.02
done
normal_state_pid=$(jq -r '.supervisor_pid // 0' "$normal_state" 2>/dev/null || echo 0)
normal_group=$(jq -r '.group_id // 0' "$normal_state" 2>/dev/null || echo 0)
jq -e '((keys | sort) == ["group_id","schema_version","supervisor_pid"]) and .schema_version==1' "$normal_state" >/dev/null 2>&1 \
    && ok "boundary handshake uses an allowlisted schema" || bad "boundary handshake schema invalid"
eq "boundary handshake permissions" 600 "$(stat -c '%a' "$normal_state" 2>/dev/null || echo missing)"
eq "boundary handshake identifies supervisor" "$BOUNDARY_PID" "$normal_state_pid"
if [[ "$(_ralph_process_parent_pid "$normal_group" 2>/dev/null || true)" == "$BOUNDARY_PID" &&
      "$(_ralph_process_group_id "$normal_group" 2>/dev/null || true)" == "$normal_group" &&
      "$(_ralph_process_session_id "$normal_group" 2>/dev/null || true)" == "$normal_group" ]]; then
    ok "child starts as an isolated session and process-group leader"
else
    bad "child boundary identity is not isolated"
fi
if register_supervised_process "$BOUNDARY_PID" provider "$normal_state" "$normal_ack"; then
    ok "validated boundary registration succeeds"
else
    bad "validated boundary registration failed"
fi
wait "$BOUNDARY_PID"
normal_rc=$?
eq "supervisor preserves provider exit code" 7 "$normal_rc"
eq "supervisor captures stdout exactly" "answer" "$(cat "$normal_output" 2>/dev/null)"
grep -q '^diagnostic$' "$normal_log" && ok "supervisor captures stderr in log only" || bad "supervisor stderr capture missing"
grep -q 'diagnostic' "$normal_output" && bad "supervisor leaked stderr into provider output" || ok "provider output excludes stderr"
[[ ! -e "$normal_state" && ! -e "$normal_ack" ]] && ok "ephemeral boundary handshake is removed" || bad "boundary handshake was retained"
unregister_child_process "$BOUNDARY_PID"
BOUNDARY_PID=""

echo "== group identity mismatch is non-destructive =="
export RUN_DIR="$TMP/supervisor-identity"
mkdir -p "$RUN_DIR"
if launch_supervised_fixture "$RUN_DIR/provider.log" "$RUN_DIR/provider.out" \
    bash -c 'trap "" TERM; while :; do sleep 1; done'; then
    identity_supervisor="$BOUNDARY_PID"
    identity_group="${RALPH_CHILD_GROUP_IDS[$identity_supervisor]}"
    identity_group_token="${RALPH_CHILD_GROUP_START_TOKENS[$identity_supervisor]}"
    RALPH_CHILD_GROUP_START_TOKENS["$identity_supervisor"]="deliberately-stale-group-token"
    terminate_owned_process "$identity_supervisor" provider signal 0
    if _ralph_owned_group_is_running "$identity_group" "$identity_group_token"; then
        ok "mismatched group-leader token prevents signaling"
    else
        bad "mismatched group-leader token signaled an owned boundary"
    fi
    eq "group mismatch cleanup outcome" already_exited "$_RALPH_LAST_CLEANUP_OUTCOME"
    RALPH_CHILD_GROUP_START_TOKENS["$identity_supervisor"]="$identity_group_token"
    terminate_owned_process "$identity_supervisor" provider signal 0
    wait "$identity_supervisor" 2>/dev/null || true
    _ralph_owned_group_is_running "$identity_group" "$identity_group_token" \
        && bad "restored group cleanup left a process" || ok "restored group identity permits cleanup"
    unregister_child_process "$identity_supervisor"
else
    bad "identity boundary fixture failed to launch"
fi
BOUNDARY_PID=""

echo "== supervisor waits for in-group descendants =="
export RUN_DIR="$TMP/supervisor-descendant"
mkdir -p "$RUN_DIR"
export SUPERVISED_DESCENDANT_PID_FILE="$RUN_DIR/descendant.pid"
daemon_started=$(_ralph_epoch_ms)
if launch_supervised_fixture "$RUN_DIR/provider.log" "$RUN_DIR/provider.out" \
    bash -c 'sleep 1 & printf "%s\n" "$!" >"$SUPERVISED_DESCENDANT_PID_FILE"; exit 0'; then
    daemon_supervisor="$BOUNDARY_PID"
    daemon_group="${RALPH_CHILD_GROUP_IDS[$daemon_supervisor]}"
    for _ in {1..100}; do
        [[ -s "$SUPERVISED_DESCENDANT_PID_FILE" ]] && ! kill -0 "$daemon_group" 2>/dev/null && break
        sleep 0.02
    done
    daemon_child=$(cat "$SUPERVISED_DESCENDANT_PID_FILE" 2>/dev/null || true)
    daemon_child_token=$(_ralph_process_start_token "$daemon_child" 2>/dev/null || true)
    if ! kill -0 "$daemon_group" 2>/dev/null &&
       _ralph_process_is_running "$daemon_supervisor" "${RALPH_CHILD_START_TOKENS[$daemon_supervisor]}"; then
        ok "supervisor stays alive after the direct child exits"
    else
        bad "supervisor reported completion before direct-child handoff"
    fi
    wait "$daemon_supervisor"
    daemon_rc=$?
    daemon_finished=$(_ralph_epoch_ms)
    daemon_elapsed=$((daemon_finished - daemon_started))
    eq "descendant run preserves direct-child success" 0 "$daemon_rc"
    [[ "$daemon_elapsed" -ge 700 ]] && ok "completion waits for the in-group descendant" || bad "completion returned early (${daemon_elapsed}ms)"
    _ralph_process_is_running "$daemon_child" "$daemon_child_token" \
        && bad "natural descendant survived supervisor completion" || ok "natural descendant is reaped before completion"
    unregister_child_process "$daemon_supervisor"
else
    bad "descendant boundary fixture failed to launch"
fi
BOUNDARY_PID=""

echo "== late-fork shutdown race =="
export RUN_DIR="$TMP/supervisor-late-fork"
mkdir -p "$RUN_DIR"
cat >"$TMP/provider-late-fork" <<'SH'
#!/bin/bash
trap '(
    trap "" TERM
    printf "%s\n" "$BASHPID" >"$LATE_FORK_PID_FILE"
    while :; do sleep 1; done
) &
trap "" TERM' TERM
printf "%s\n" "$$" >"$LATE_FORK_READY_FILE"
while :; do sleep 1; done
SH
chmod +x "$TMP/provider-late-fork"
export LATE_FORK_PID_FILE="$RUN_DIR/late.pid"
export LATE_FORK_READY_FILE="$RUN_DIR/ready.pid"
if launch_supervised_fixture "$RUN_DIR/provider.log" "$RUN_DIR/provider.out" "$TMP/provider-late-fork"; then
    late_supervisor="$BOUNDARY_PID"
    late_group="${RALPH_CHILD_GROUP_IDS[$late_supervisor]}"
    late_group_token="${RALPH_CHILD_GROUP_START_TOKENS[$late_supervisor]}"
    for _ in {1..100}; do [[ -s "$LATE_FORK_READY_FILE" ]] && break; sleep 0.02; done
    terminate_owned_process "$late_supervisor" provider signal 1
    wait "$late_supervisor" 2>/dev/null || true
    late_pid=$(cat "$LATE_FORK_PID_FILE" 2>/dev/null || true)
    valid_pid "$late_pid" && ok "provider forked a child after TERM began" || bad "late-fork fixture did not run"
    late_state=$(_ralph_process_state "$late_pid" 2>/dev/null || true)
    if kill -0 "$late_pid" 2>/dev/null && [[ "$late_state" != Z* && "$late_state" != X* ]]; then
        bad "late-forked child escaped group cleanup"
    else
        ok "late-forked child is removed by group escalation"
    fi
    _ralph_owned_group_is_running "$late_group" "$late_group_token" \
        && bad "late-fork process group survived cleanup" || ok "late-fork process group is empty"
    eq "late-fork cleanup escalates" kill "$_RALPH_LAST_CLEANUP_OUTCOME"
    unregister_child_process "$late_supervisor"
else
    bad "late-fork boundary fixture failed to launch"
fi
BOUNDARY_PID=""

echo "== allowlisted bounded cleanup evidence =="
export RUN_DIR="$TMP/run"
export RALPH_PROCESS_CLEANUP_FILE="$RUN_DIR/process-cleanup.json"
mkdir -p "$RUN_DIR"
_ralph_record_process_cleanup_event provider normal already_exited 0
evidence="$RALPH_PROCESS_CLEANUP_FILE"
jq empty "$evidence" 2>/dev/null && ok "cleanup artifact is valid JSON" || bad "cleanup artifact is invalid"
eq "cleanup artifact permissions" 600 "$(stat -c '%a' "$evidence")"
jq -e 'keys | sort == ["artifact","events","schema_version","summary","updated_at"]' "$evidence" >/dev/null \
    && ok "cleanup artifact uses top-level allowlist" || bad "cleanup artifact top-level schema drifted"
jq -e '.events[0] | keys | sort == ["duration_ms","finished_at","kind","outcome","trigger"]' "$evidence" >/dev/null \
    && ok "cleanup event uses field allowlist" || bad "cleanup event schema drifted"
jq -e '.events[0] | .kind=="provider" and .trigger=="normal" and .outcome=="already_exited" and .duration_ms==0' "$evidence" >/dev/null \
    && ok "normal provider completion recorded" || bad "normal provider completion missing"
if _ralph_record_process_cleanup_event provider 'TOKEN=must-not-appear' term 1; then
    bad "invalid cleanup trigger accepted"
else
    ok "invalid cleanup trigger rejected"
fi
if grep -q 'must-not-appear' "$evidence"; then
    bad "rejected sensitive value leaked into cleanup artifact"
else
    ok "cleanup artifact excludes rejected values"
fi
tampered="$TMP/tampered-cleanup.json"
jq '.unexpected = "must-not-persist"
    | .events[0].command = "must-not-persist"
    | .events += [{
        kind: "provider", trigger: "normal", outcome: "term",
        duration_ms: 1, finished_at: "must-not-persist"
      }]' "$evidence" >"$tampered"
mv -f "$tampered" "$evidence"
_ralph_record_process_cleanup_event live_smoke verification term 2
jq -e '((keys | sort) == ["artifact","events","schema_version","summary","updated_at"])
       and ([.events[] | (keys | sort)] | all(. == ["duration_ms","finished_at","kind","outcome","trigger"]))' "$evidence" >/dev/null \
    && ok "cleanup rewrite strips non-allowlisted fields" || bad "cleanup rewrite retained schema injection"
grep -q 'must-not-persist' "$evidence" \
    && bad "cleanup rewrite retained injected values" || ok "cleanup rewrite drops injected values"
for i in {1..55}; do
    _ralph_record_process_cleanup_event provider normal already_exited "$i"
done
eq "cleanup event history is bounded" 50 "$(jq -r '.events | length' "$evidence")"
eq "cleanup summary matches retained events" 50 "$(jq -r '.summary.event_count' "$evidence")"
eq "cleanup summary tracks max latency" 55 "$(jq -r '.summary.max_duration_ms' "$evidence")"

echo "== PID ownership identity =="
export RALPH_PROCESS_CLEANUP_FILE="$TMP/identity-cleanup.json"
sleep 30 &
IDENTITY_PID=$!
register_child_process "$IDENTITY_PID" provider
RALPH_CHILD_START_TOKENS["$IDENTITY_PID"]="deliberately-stale-token"
terminate_owned_process "$IDENTITY_PID" provider exit 0
if kill -0 "$IDENTITY_PID" 2>/dev/null; then
    ok "mismatched ownership token prevents signaling"
else
    bad "mismatched ownership token signaled an unowned PID"
fi
RALPH_CHILD_START_TOKENS["$IDENTITY_PID"]=""
terminate_owned_process "$IDENTITY_PID" provider exit 0
if kill -0 "$IDENTITY_PID" 2>/dev/null; then
    ok "missing ownership token prevents signaling"
else
    bad "missing ownership token was resampled and signaled"
fi
jq -e '.events[-1] | .kind=="provider" and .trigger=="exit" and .outcome=="already_exited"' "$RALPH_PROCESS_CLEANUP_FILE" >/dev/null \
    && ok "PID mismatch records a non-destructive outcome" || bad "PID mismatch evidence missing"
unregister_child_process "$IDENTITY_PID"
kill -KILL "$IDENTITY_PID" 2>/dev/null || true
wait "$IDENTITY_PID" 2>/dev/null || true
IDENTITY_PID=""

echo "== reparented descendant cleanup =="
export RALPH_PROCESS_CLEANUP_FILE="$TMP/descendant-cleanup.json"
descendant_pid_file="$TMP/descendant.pid"
cat >"$TMP/provider-with-stubborn-child" <<'SH'
#!/bin/bash
trap 'exit 0' TERM
(
    trap '' TERM
    exec sleep 30
) &
printf '%s\n' "$!" >"$DESCENDANT_PID_FILE"
wait
SH
chmod +x "$TMP/provider-with-stubborn-child"
DESCENDANT_PID_FILE="$descendant_pid_file" "$TMP/provider-with-stubborn-child" &
DESC_ROOT_PID=$!
for _ in {1..30}; do
    [[ -s "$descendant_pid_file" ]] && break
    sleep 0.1
done
DESC_CHILD_PID=$(cat "$descendant_pid_file" 2>/dev/null || true)
descendant_token=$(_ralph_process_start_token "$DESC_CHILD_PID" 2>/dev/null || true)
register_child_process "$DESC_ROOT_PID" provider
terminate_owned_process "$DESC_ROOT_PID" provider signal 1
wait "$DESC_ROOT_PID" 2>/dev/null || true
if ! _ralph_process_is_running "$DESC_CHILD_PID" "$descendant_token"; then
    ok "stubborn descendant is reaped after root exits on TERM"
else
    bad "stubborn descendant survived root process cleanup"
fi
jq -e '.events[-1] | .kind=="provider" and .trigger=="signal" and .outcome=="kill"' "$RALPH_PROCESS_CLEANUP_FILE" >/dev/null \
    && ok "descendant KILL escalation is recorded" || bad "descendant escalation evidence missing"
unregister_child_process "$DESC_ROOT_PID"
DESC_ROOT_PID=""
DESC_CHILD_PID=""

echo "== graceful TERM cleanup =="
export RALPH_PROCESS_CLEANUP_FILE="$TMP/term-cleanup.json"
bash -c 'trap "exit 0" TERM; while :; do sleep 1; done' &
TERM_PID=$!
sleep 0.2
terminate_owned_process "$TERM_PID" provider signal 1
wait "$TERM_PID" 2>/dev/null || true
if kill -0 "$TERM_PID" 2>/dev/null; then
    bad "TERM-cleaned process survived"
else
    ok "TERM-cleaned process exited"
fi
jq -e '.events[-1] | .kind=="provider" and .trigger=="signal" and .outcome=="term" and (.duration_ms >= 0)' "$RALPH_PROCESS_CLEANUP_FILE" >/dev/null \
    && ok "TERM cleanup evidence recorded" || bad "TERM cleanup evidence missing"
TERM_PID=""

echo "== TERM-to-KILL escalation =="
export RALPH_PROCESS_CLEANUP_FILE="$TMP/kill-cleanup.json"
bash -c 'trap "" TERM; while :; do sleep 1; done' &
KILL_PID=$!
sleep 0.2
terminate_owned_process "$KILL_PID" provider timeout 0
wait "$KILL_PID" 2>/dev/null || true
if kill -0 "$KILL_PID" 2>/dev/null; then
    bad "KILL-escalated process survived"
else
    ok "KILL-escalated process exited"
fi
jq -e '.events[-1] | .trigger=="timeout" and .outcome=="kill" and (.duration_ms >= 0)' "$RALPH_PROCESS_CLEANUP_FILE" >/dev/null \
    && ok "KILL escalation evidence recorded" || bad "KILL escalation evidence missing"
eq "KILL escalation summary incremented" 1 "$(jq -r '.summary.kill_escalations' "$RALPH_PROCESS_CLEANUP_FILE")"
KILL_PID=""

echo "== parent-death guardian evidence =="
cat >"$TMP/stubborn-provider" <<'SH'
#!/bin/bash
trap "" TERM
while :; do sleep 1; done
SH
chmod +x "$TMP/stubborn-provider"
guardian_dir="$TMP/guardian"
mkdir -p "$guardian_dir"
bash -c '
    source "$1/lib/processes.sh"
    export RUN_DIR="$2"
    export RALPH_PROCESS_CLEANUP_FILE="$2/process-cleanup.json"
    "$3" &
    child=$!
    printf "%s\n" "$child" >"$2/child.pid"
    start_child_guardian "$child" "$BASHPID" provider
    printf "%s\n" "$_RALPH_LAST_GUARDIAN_PID" >"$2/guardian.pid"
    wait "$child"
' _ "$R" "$guardian_dir" "$TMP/stubborn-provider" &
OWNER_PID=$!
for _ in {1..50}; do
    [[ -s "$guardian_dir/child.pid" && -s "$guardian_dir/guardian.pid" ]] && break
    sleep 0.1
done
GUARD_CHILD_PID=$(cat "$guardian_dir/child.pid" 2>/dev/null || true)
GUARDIAN_PID=$(cat "$guardian_dir/guardian.pid" 2>/dev/null || true)
if valid_pid "$GUARD_CHILD_PID" && valid_pid "$GUARDIAN_PID"; then
    ok "guardian fixture recorded valid PIDs"
else
    bad "guardian fixture PID evidence missing"
fi
kill -KILL "$OWNER_PID" 2>/dev/null || true
wait "$OWNER_PID" 2>/dev/null || true
OWNER_PID=""
for _ in {1..80}; do
    if ! kill -0 "$GUARD_CHILD_PID" 2>/dev/null &&
       ! kill -0 "$GUARDIAN_PID" 2>/dev/null &&
       jq -e '.events | any(.trigger=="parent_death")' "$guardian_dir/process-cleanup.json" >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done
if kill -0 "$GUARD_CHILD_PID" 2>/dev/null || kill -0 "$GUARDIAN_PID" 2>/dev/null; then
    bad "parent-death cleanup left an owned process"
else
    ok "parent-death cleanup reaped provider and guardian"
fi
jq -e '.events[-1] | .kind=="provider" and .trigger=="parent_death" and .outcome=="kill" and (.duration_ms >= 0)' "$guardian_dir/process-cleanup.json" >/dev/null \
    && ok "parent-death cleanup evidence recorded" || bad "parent-death cleanup evidence missing"
GUARD_CHILD_PID=""
GUARDIAN_PID=""

printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
