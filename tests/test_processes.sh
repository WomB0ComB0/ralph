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

valid_pid() {
    local pid="${1:-}"
    [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 1 ))
}

cleanup() {
    local pid
    for pid in "$TERM_PID" "$KILL_PID" "$DISCOVERY_PID" "$IDENTITY_PID" "$DESC_ROOT_PID" "$DESC_CHILD_PID" "$OWNER_PID" "$GUARD_CHILD_PID" "$GUARDIAN_PID"; do
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
