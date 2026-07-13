#!/bin/bash
# End-to-end unattended reliability soak using only disposable local fixtures.
set -uo pipefail

R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CYCLES="${RALPH_SOAK_CYCLES:-1}"
DURATION="${RALPH_SOAK_DURATION:-0}"
SEED="${RALPH_SOAK_SEED:-20260713}"
RETENTION="${RALPH_SOAK_RETENTION:-6}"
OUTPUT=""
KEEP=false

usage() {
    printf '%s\n' "Usage: $0 [--cycles N] [--duration SECONDS] [--seed N] [--output FILE] [--keep-workdir]"
    printf '%s\n' "One cycle injects both TERM and KILL in seeded random order, recovering after each."
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cycles) CYCLES="${2:-}"; shift 2 ;;
        --duration) DURATION="${2:-}"; shift 2 ;;
        --seed) SEED="${2:-}"; shift 2 ;;
        --output) OUTPUT="${2:-}"; shift 2 ;;
        --keep-workdir) KEEP=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

for value in "$CYCLES" "$DURATION" "$SEED" "$RETENTION"; do
    [[ "$value" =~ ^[0-9]+$ ]] || { printf 'Numeric options must be non-negative integers.\n' >&2; exit 2; }
done
[[ "$CYCLES" -gt 0 ]] || { printf -- '--cycles must be greater than zero.\n' >&2; exit 2; }
[[ "$RETENTION" -ge 4 ]] || { printf 'RALPH_SOAK_RETENTION must be at least 4.\n' >&2; exit 2; }

for dependency in jq git curl bc sqlite3 python3; do
    command -v "$dependency" >/dev/null 2>&1 || {
        printf 'Missing soak dependency: %s\n' "$dependency" >&2
        exit 2
    }
done

WORK=$(mktemp -d)
PROJECT="$WORK/project"
BIN="$WORK/bin"
HOME_DIR="$WORK/home"
RESULTS_FILE="$WORK/results.jsonl"
FAILURES_FILE="$WORK/failures.jsonl"
ACTIVE_RALPH_PID=""
ACTIVE_LABEL=""
START_EPOCH=$(date +%s)
STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RANDOM=$SEED

if [[ -z "$OUTPUT" ]]; then
    OUTPUT="/tmp/ralph-unattended-soak-${START_EPOCH}-$$.json"
elif [[ "$OUTPUT" != /* ]]; then
    OUTPUT="$(pwd)/$OUTPUT"
fi
mkdir -p "$(dirname "$OUTPUT")" "$PROJECT" "$BIN" "$HOME_DIR" "$WORK/pids"
: >"$RESULTS_FILE"
: >"$FAILURES_FILE"

cleanup() {
    if [[ -n "${ACTIVE_RALPH_PID:-}" ]] && kill -0 "$ACTIVE_RALPH_PID" 2>/dev/null; then
        kill -TERM "$ACTIVE_RALPH_PID" 2>/dev/null || true
        wait "$ACTIVE_RALPH_PID" 2>/dev/null || true
    fi
    if [[ "$KEEP" == "true" ]]; then
        printf 'Soak workdir retained: %s\n' "$WORK" >&2
    else
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

add_failure() {
    local phase="$1" detail="$2"
    jq -nc --arg phase "$phase" --arg detail "$detail" '{phase:$phase,detail:$detail}' >>"$FAILURES_FILE"
    printf 'FAIL [%s] %s\n' "$phase" "$detail" >&2
}

valid_fixture_pid() { local pid="${1:-}"; [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 1 )); }
fixture_pid_alive() { valid_fixture_pid "${1:-}" && kill -0 "$1" 2>/dev/null; }
kill_fixture_pids() {
    local pid
    for pid in "$@"; do
        valid_fixture_pid "$pid" && kill -KILL "$pid" 2>/dev/null || true
    done
}

cat >"$BIN/opencode" <<'SH'
#!/bin/bash
if [[ "${1:-}" == "models" ]]; then
    printf '%s\n' "soak/local"
    exit 0
fi
case "${SOAK_PROVIDER_MODE:-complete}" in
    complete)
        printf '%s\n' "bounded fixture iteration complete"
        printf '%s\n' "<promise>COMPLETE</promise>"
        ;;
    stall)
        printf '%s\n' "$$" >"$SOAK_PROVIDER_PID_FILE"
        sleep "${SOAK_STALL_SECONDS:-300}" &
        printf '%s\n' "$!" >"$SOAK_PROVIDER_CHILD_PID_FILE"
        wait
        ;;
    *)
        exit 64
        ;;
esac
SH

cat >"$BIN/bd" <<'SH'
#!/bin/bash
while [[ $# -gt 0 ]]; do
    case "$1" in
        --db) shift 2 ;;
        --*) shift ;;
        *) break ;;
    esac
done
command="${1:-}"
shift || true
case "$command" in
    info) printf '%s\n' "Backend: sqlite" ;;
    count)
        status=""
        while [[ $# -gt 0 ]]; do
            [[ "$1" == "--status" ]] && status="${2:-}" && shift 2 || shift
        done
        [[ "$status" == "closed" ]] && printf '1\n' || printf '0\n'
        ;;
    ready|list) exit 0 ;;
    init|create|close|update|vc) exit 0 ;;
    *) exit 0 ;;
esac
SH

chmod +x "$BIN/opencode" "$BIN/bd"
printf '%s\n' '# Ralph unattended soak fixture' 'Work only inside this disposable project.' >"$PROJECT/AGENTS.md"
git -C "$PROJECT" init -q
git -C "$PROJECT" config user.email soak@localhost
git -C "$PROJECT" config user.name "Ralph Soak"
git -C "$PROJECT" add AGENTS.md
git -C "$PROJECT" commit -qm "initialize soak fixture"

latest_target() {
    readlink "$PROJECT/.ralph/runs/latest" 2>/dev/null || true
}

wait_for_new_manifest() {
    local previous="$1" timeout="${2:-20}" started target file
    started=$SECONDS
    while [[ $((SECONDS - started)) -lt "$timeout" ]]; do
        target=$(latest_target)
        file="$target/run.json"
        if [[ -n "$target" && "$target" != "$previous" && -f "$file" ]]; then
            printf '%s\n' "$file"
            return 0
        fi
        sleep 0.1
    done
    return 1
}

wait_for_phase() {
    local manifest="$1" expected="$2" timeout="${3:-20}" started phase
    started=$SECONDS
    while [[ $((SECONDS - started)) -lt "$timeout" ]]; do
        phase=$(jq -r '.phase // empty' "$manifest" 2>/dev/null || true)
        [[ "$phase" == "$expected" ]] && return 0
        sleep 0.1
    done
    return 1
}

launch_run() {
    local mode="$1" resume="$2" label="$3" previous resume_args=()
    previous=$(latest_target)
    [[ "$resume" == "true" ]] && resume_args=(--resume)
    rm -f "$WORK/pids/$label.pid" "$WORK/pids/$label-child.pid"
    (
        cd "$PROJECT" || exit 1
        env \
            HOME="$HOME_DIR" \
            PATH="$BIN:$PATH" \
            RALPH_OPENCODE_JSON=0 \
            RALPH_TOOL_TIMEOUT=300 \
            RALPH_TOOL_IDLE_TIMEOUT=0 \
            RALPH_CHILD_TERM_GRACE=1 \
            RALPH_RUN_RETENTION="$RETENTION" \
            RALPH_REQUIRE_VERIFY_ON_COMPLETE=0 \
            RALPH_REQUIRE_QUALITY_ON_COMPLETE=0 \
            RALPH_VERIFY_DECLARED_COMMANDS=0 \
            AI_RETRY_ATTEMPTS=1 \
            AI_RETRY_BASE_DELAY=0 \
            SOAK_PROVIDER_MODE="$mode" \
            SOAK_STALL_SECONDS=300 \
            SOAK_PROVIDER_PID_FILE="$WORK/pids/$label.pid" \
            SOAK_PROVIDER_CHILD_PID_FILE="$WORK/pids/$label-child.pid" \
            "$R/ralph.sh" --tool opencode --model soak/local --max-iterations 200 \
                --once --unattended --no-sandbox --no-archive "${resume_args[@]}"
    ) >"$WORK/$label.log" 2>&1 &
    ACTIVE_RALPH_PID=$!
    ACTIVE_LABEL="$label"
    if ! ACTIVE_MANIFEST=$(wait_for_new_manifest "$previous" 25); then
        wait_active
        return 1
    fi
    return 0
}

wait_active() {
    local rc=0
    wait "$ACTIVE_RALPH_PID" || rc=$?
    ACTIVE_RALPH_PID=""
    LAST_EXIT_CODE=$rc
}

provider_tree_clean() {
    local label="$1" pid child started
    PROVIDER_CLEAN_DETAIL=""
    pid=$(cat "$WORK/pids/$label.pid" 2>/dev/null || true)
    child=$(cat "$WORK/pids/$label-child.pid" 2>/dev/null || true)
    if ! valid_fixture_pid "$pid" || ! valid_fixture_pid "$child"; then
        PROVIDER_CLEAN_DETAIL="provider PID evidence was missing or invalid"
        return 1
    fi
    started=$SECONDS
    while [[ $((SECONDS - started)) -lt 8 ]]; do
        if ! fixture_pid_alive "$pid" && ! fixture_pid_alive "$child"; then
            return 0
        fi
        sleep 0.1
    done
    kill_fixture_pids "$pid" "$child"
    PROVIDER_CLEAN_DETAIL="provider process tree survived the cleanup window"
    return 1
}

checkpoint_value() {
    local file="$PROJECT/.ralph/state/checkpoint.txt" value=0
    [[ -f "$file" ]] && value=$(cat "$file" 2>/dev/null || echo 0)
    [[ "$value" =~ ^[0-9]+$ ]] || value=0
    printf '%s\n' "$value"
}

run_completion() {
    local label="$1"
    if ! launch_run complete true "$label"; then
        add_failure "$label" "run manifest did not appear"
        return 1
    fi
    wait_active
    LAST_COMPLETION_MANIFEST="$ACTIVE_MANIFEST"
    local status reason
    status=$(jq -r '.status // empty' "$LAST_COMPLETION_MANIFEST")
    reason=$(jq -r '.reason // empty' "$LAST_COMPLETION_MANIFEST")
    if [[ "$LAST_EXIT_CODE" -ne 0 || "$status" != "completed" || "$reason" != "completion_signal" ]]; then
        add_failure "$label" "completion run exit=$LAST_EXIT_CODE status=$status reason=$reason"
        return 1
    fi
    return 0
}

run_fault() {
    local cycle="$1" signal="$2" label="cycle-${cycle}-${signal,,}" before after
    local fault_manifest fault_exit_code fault_status fault_reason provider_clean=true recovery_ok=true recovery_id="" reconciled=false
    before=$(checkpoint_value)

    if ! launch_run stall true "$label"; then
        add_failure "$label" "fault run manifest did not appear"
        return 1
    fi
    fault_manifest="$ACTIVE_MANIFEST"
    if ! wait_for_phase "$fault_manifest" provider_execution 20; then
        add_failure "$label" "provider_execution phase was not reached"
        kill -TERM "$ACTIVE_RALPH_PID" 2>/dev/null || true
        wait_active
        return 1
    fi
    for _ in {1..100}; do
        [[ -s "$WORK/pids/$label.pid" && -s "$WORK/pids/$label-child.pid" ]] && break
        sleep 0.1
    done

    kill "-$signal" "$ACTIVE_RALPH_PID" 2>/dev/null || true
    wait_active
    fault_exit_code="$LAST_EXIT_CODE"
    provider_tree_clean "$label" || {
        provider_clean=false
        add_failure "$label" "$signal cleanup: ${PROVIDER_CLEAN_DETAIL:-unknown process cleanup failure}"
    }

    fault_status=$(jq -r '.status // empty' "$fault_manifest")
    fault_reason=$(jq -r '.reason // empty' "$fault_manifest")
    if [[ "$signal" == "TERM" ]]; then
        [[ "$fault_exit_code" -eq 143 && "$fault_status" == "interrupted" && "$fault_reason" == "signal_term" ]] ||
            add_failure "$label" "TERM exit=$fault_exit_code status=$fault_status reason=$fault_reason"
    else
        [[ "$fault_exit_code" -eq 137 && "$fault_status" == "running" ]] ||
            add_failure "$label" "KILL exit=$fault_exit_code pre-recovery status=$fault_status"
    fi

    if run_completion "$label-recovery"; then
        recovery_id=$(jq -r '.run_id' "$LAST_COMPLETION_MANIFEST")
    else
        recovery_ok=false
    fi
    after=$(checkpoint_value)
    [[ "$after" -gt "$before" ]] ||
        add_failure "$label" "checkpoint did not advance across recovery ($before -> $after)"

    if [[ "$signal" == "KILL" && -n "$recovery_id" ]]; then
        fault_status=$(jq -r '.status // empty' "$fault_manifest")
        fault_reason=$(jq -r '.reason // empty' "$fault_manifest")
        if [[ "$fault_status" == "interrupted" &&
              "$fault_reason" == "unclean_exit_detected" &&
              "$(jq -r '.recovered_by_run_id // empty' "$fault_manifest")" == "$recovery_id" ]]; then
            reconciled=true
        else
            add_failure "$label" "KILL manifest was not reconciled by recovery run"
        fi
    elif [[ "$signal" == "TERM" ]]; then
        reconciled=true
    fi

    jq -nc \
        --argjson cycle "$cycle" \
        --arg signal "$signal" \
        --arg run_id "$(jq -r '.run_id' "$fault_manifest")" \
        --arg status "$fault_status" \
        --arg reason "$fault_reason" \
        --argjson exit_code "$fault_exit_code" \
        --argjson checkpoint_before "$before" \
        --argjson checkpoint_after "$after" \
        --argjson provider_clean "$provider_clean" \
        --argjson recovery_ok "$recovery_ok" \
        --argjson reconciled "$reconciled" \
        '{cycle:$cycle,signal:$signal,run_id:$run_id,status:$status,reason:$reason,exit_code:$exit_code,checkpoint_before:$checkpoint_before,checkpoint_after:$checkpoint_after,provider_clean:$provider_clean,recovery_ok:$recovery_ok,reconciled:$reconciled}' \
        >>"$RESULTS_FILE"
}

printf 'Starting Ralph unattended soak: cycles=%s duration=%ss seed=%s retention=%s\n' "$CYCLES" "$DURATION" "$SEED" "$RETENTION"
baseline_ok=false
if launch_run complete false baseline; then
    wait_active
    baseline_status=$(jq -r '.status // empty' "$ACTIVE_MANIFEST")
    if [[ "$LAST_EXIT_CODE" -eq 0 && "$baseline_status" == "completed" ]]; then
        baseline_ok=true
    else
        add_failure baseline "exit=$LAST_EXIT_CODE status=$baseline_status"
    fi
else
    add_failure baseline "initial manifest did not appear (exit=${LAST_EXIT_CODE:-unknown})"
    tail -n 20 "$WORK/baseline.log" >&2 || true
fi

completed_cycles=0
if [[ "$baseline_ok" == "true" ]]; then
    for ((cycle = 1; cycle <= CYCLES; cycle++)); do
        if [[ "$DURATION" -gt 0 && "$completed_cycles" -gt 0 &&
              $(( $(date +%s) - START_EPOCH )) -ge "$DURATION" ]]; then
            break
        fi
        if (( RANDOM % 2 )); then
            signals=(TERM KILL)
        else
            signals=(KILL TERM)
        fi
        for signal in "${signals[@]}"; do
            run_fault "$cycle" "$signal" || true
        done
        completed_cycles=$cycle
    done
fi

retained_runs=$(find "$PROJECT/.ralph/runs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
[[ "$retained_runs" -le "$RETENTION" ]] ||
    add_failure retention "retained $retained_runs runs with limit $RETENTION"

finished_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
elapsed=$(( $(date +%s) - START_EPOCH ))
failure_count=$(wc -l <"$FAILURES_FILE" | tr -d ' ')
result_count=$(wc -l <"$RESULTS_FILE" | tr -d ' ')
status=pass
[[ "$failure_count" -eq 0 ]] || status=fail
results=$(jq -s '.' "$RESULTS_FILE")
failures=$(jq -s '.' "$FAILURES_FILE")

tmp_output="$OUTPUT.tmp.$$"
jq -n \
    --arg status "$status" \
    --arg started_at "$STARTED_AT" \
    --arg finished_at "$finished_at" \
    --argjson duration_seconds "$elapsed" \
    --argjson seed "$SEED" \
    --argjson requested_cycles "$CYCLES" \
    --argjson completed_cycles "$completed_cycles" \
    --argjson fault_runs "$result_count" \
    --argjson retention_limit "$RETENTION" \
    --argjson retained_runs "$retained_runs" \
    --argjson results "$results" \
    --argjson failures "$failures" \
    '{schema_version:1,status:$status,started_at:$started_at,finished_at:$finished_at,duration_seconds:$duration_seconds,seed:$seed,requested_cycles:$requested_cycles,completed_cycles:$completed_cycles,fault_runs:$fault_runs,retention:{limit:$retention_limit,retained_runs:$retained_runs},results:$results,failures:$failures}' \
    >"$tmp_output"
chmod 600 "$tmp_output"
mv -f "$tmp_output" "$OUTPUT"

printf 'Soak %s: cycles=%s faults=%s failures=%s retained=%s/%s\n' \
    "$status" "$completed_cycles" "$result_count" "$failure_count" "$retained_runs" "$RETENTION"
printf 'Report: %s\n' "$OUTPUT"
[[ "$failure_count" -eq 0 ]]
