#!/bin/bash

# Background process ownership for one Ralph shell. PIDs are kept in memory so
# read-only commands and separate Ralph invocations never share cleanup state.
declare -a RALPH_CHILD_PIDS=()
declare -A RALPH_CHILD_KINDS=()
declare -A RALPH_CHILD_START_TOKENS=()

register_child_process() {
    local pid="${1:-}" kind="${2:-owned}" existing token=""
    [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]] || return 1
    case "$kind" in
        provider|live_smoke|guardian|owned) ;;
        *) kind=owned ;;
    esac
    token=$(_ralph_process_start_token "$pid" 2>/dev/null || true)
    RALPH_CHILD_KINDS["$pid"]="$kind"
    RALPH_CHILD_START_TOKENS["$pid"]="$token"
    for existing in "${RALPH_CHILD_PIDS[@]}"; do
        [[ "$existing" == "$pid" ]] && return 0
    done
    RALPH_CHILD_PIDS+=("$pid")
    return 0
}

unregister_child_process() {
    local target="${1:-}" pid
    local kept=()
    for pid in "${RALPH_CHILD_PIDS[@]}"; do
        [[ "$pid" == "$target" ]] || kept+=("$pid")
    done
    RALPH_CHILD_PIDS=("${kept[@]}")
    unset 'RALPH_CHILD_KINDS[$target]' 'RALPH_CHILD_START_TOKENS[$target]'
}

_ralph_child_pids() {
    local parent="${1:-}" stat_file stat rest child
    local -a fields=()
    [[ "$parent" =~ ^[0-9]+$ ]] || return 0
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -P "$parent" 2>/dev/null || true
    elif command -v ps >/dev/null 2>&1; then
        ps -eo pid=,ppid= 2>/dev/null |
            awk -v parent="$parent" '$2 == parent { print $1 }'
    elif [[ -d /proc ]]; then
        for stat_file in /proc/[0-9]*/stat; do
            [[ -r "$stat_file" ]] || continue
            stat=$(<"$stat_file") || continue
            rest="${stat##*) }"
            fields=()
            IFS=' ' read -r -a fields <<<"$rest"
            [[ "${fields[1]:-}" == "$parent" ]] || continue
            child="${stat_file#/proc/}"
            child="${child%/stat}"
            [[ "$child" =~ ^[0-9]+$ ]] && printf '%s\n' "$child"
        done
    fi
}

_ralph_terminate_process_tree() {
    local signal="${1:-TERM}" pid="${2:-}" child
    [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]] || return 0
    while IFS= read -r child; do
        [[ -n "$child" ]] && _ralph_terminate_process_tree "$signal" "$child"
    done < <(_ralph_child_pids "$pid")
    kill "-$signal" "$pid" 2>/dev/null || true
}

_ralph_process_start_token() {
    local pid="${1:-}" stat rest
    local -a fields=()
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    if [[ -r "/proc/$pid/stat" ]]; then
        stat=$(<"/proc/$pid/stat") || return 1
        rest="${stat##*) }"
        IFS=' ' read -r -a fields <<<"$rest"
        [[ -n "${fields[19]:-}" ]] || return 1
        printf '%s\n' "${fields[19]}"
        return 0
    fi
    ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

_ralph_process_state() {
    local pid="${1:-}" stat rest
    local -a fields=()
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    if [[ -r "/proc/$pid/stat" ]]; then
        stat=$(<"/proc/$pid/stat") || return 1
        rest="${stat##*) }"
        IFS=' ' read -r -a fields <<<"$rest"
        [[ -n "${fields[0]:-}" ]] || return 1
        printf '%s\n' "${fields[0]}"
        return 0
    fi
    ps -o stat= -p "$pid" 2>/dev/null | awk '{print $1}'
}

_ralph_process_matches_token() {
    local pid="${1:-}" expected="${2:-}" current
    [[ -n "$expected" ]] || return 1
    current=$(_ralph_process_start_token "$pid" 2>/dev/null || true)
    [[ -n "$current" && "$current" == "$expected" ]]
}

_ralph_process_is_running() {
    local pid="${1:-}" expected="${2:-}" state
    [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 && -n "$expected" ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    _ralph_process_matches_token "$pid" "$expected" || return 1
    state=$(_ralph_process_state "$pid" 2>/dev/null || true)
    case "$state" in
        Z*|X*) return 1 ;;
    esac
    return 0
}

_ralph_epoch_ms() {
    local value
    value=$(date +%s%3N 2>/dev/null || true)
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$value"
    else
        printf '%s000\n' "$(date +%s)"
    fi
}

_ralph_process_cleanup_file() {
    if [[ -n "${RALPH_PROCESS_CLEANUP_FILE:-}" ]]; then
        printf '%s\n' "$RALPH_PROCESS_CLEANUP_FILE"
    elif [[ -n "${RUN_DIR:-}" ]]; then
        printf '%s/process-cleanup.json\n' "$RUN_DIR"
    elif [[ -n "${ARTIFACT_DIR:-}" ]]; then
        printf '%s/process-cleanup.json\n' "$ARTIFACT_DIR"
    else
        return 1
    fi
}

# Self-benchmarking: next, aggregate cleanup latency percentiles across retained
# runs without expanding the per-run event detail.
_ralph_record_process_cleanup_event() {
    local kind="${1:-}" trigger="${2:-}" outcome="${3:-}" duration_ms="${4:-0}"
    local file now tmp lock_file lock_fd lock_wait=3

    case "$kind" in provider|live_smoke) ;; *) return 1 ;; esac
    case "$trigger" in normal|timeout|quiescence|verification|signal|exit|parent_death) ;; *) return 1 ;; esac
    case "$outcome" in already_exited|term|kill) ;; *) return 1 ;; esac
    [[ "$duration_ms" =~ ^[0-9]+$ ]] || duration_ms=0
    [[ "$duration_ms" -le 86400000 ]] || duration_ms=86400000
    command -v jq >/dev/null 2>&1 || return 1
    file=$(_ralph_process_cleanup_file) || return 0
    mkdir -p "$(dirname "$file")" 2>/dev/null || return 1
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    lock_file="${file}.lock"

    if command -v flock >/dev/null 2>&1; then
        lock_wait="${RALPH_LOCK_WAIT_SECONDS:-3}"
        [[ "$lock_wait" =~ ^[0-9]+$ ]] || lock_wait=3
        [[ "$lock_wait" -le 60 ]] || lock_wait=60
        { exec {lock_fd}>"$lock_file"; } 2>/dev/null || return 1
        chmod 600 "$lock_file" 2>/dev/null || true
        if ! flock -w "$lock_wait" "$lock_fd"; then
            exec {lock_fd}>&-
            return 1
        fi
    fi

    if [[ ! -f "$file" ]]; then
        tmp=$(mktemp "$(dirname "$file")/.process-cleanup.tmp.XXXXXX") || {
            [[ -n "${lock_fd:-}" ]] && exec {lock_fd}>&-
            return 1
        }
        if ! jq -n '{
            schema_version: 1,
            artifact: "ralph_process_cleanup",
            updated_at: null,
            summary: {
                event_count: 0,
                term_cleanups: 0,
                kill_escalations: 0,
                already_exited: 0,
                max_duration_ms: 0
            },
            events: []
        }' >"$tmp" 2>/dev/null; then
            rm -f "$tmp"
            [[ -n "${lock_fd:-}" ]] && exec {lock_fd}>&-
            return 1
        fi
        chmod 600 "$tmp" 2>/dev/null || true
        if ! mv -f "$tmp" "$file"; then
            rm -f "$tmp"
            [[ -n "${lock_fd:-}" ]] && exec {lock_fd}>&-
            return 1
        fi
    fi

    tmp=$(mktemp "$(dirname "$file")/.process-cleanup.tmp.XXXXXX") || {
        [[ -n "${lock_fd:-}" ]] && exec {lock_fd}>&-
        return 1
    }
    if jq \
        --arg kind "$kind" \
        --arg trigger "$trigger" \
        --arg outcome "$outcome" \
        --arg finished_at "$now" \
        --argjson duration_ms "$duration_ms" \
        '([(.events // [])[]?
            | select(type == "object")
            | select(.kind == "provider" or .kind == "live_smoke")
            | select(.trigger == "normal" or .trigger == "timeout"
                     or .trigger == "quiescence" or .trigger == "verification"
                     or .trigger == "signal" or .trigger == "exit"
                     or .trigger == "parent_death")
            | select(.outcome == "already_exited" or .outcome == "term"
                     or .outcome == "kill")
            | select((.duration_ms | type) == "number"
                     and .duration_ms >= 0 and .duration_ms <= 86400000
                     and (.duration_ms | floor) == .duration_ms)
            | select((.finished_at | type) == "string"
                     and (.finished_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")))
            | {kind, trigger, outcome, duration_ms, finished_at}]
           + [{
               kind: $kind,
               trigger: $trigger,
               outcome: $outcome,
               duration_ms: $duration_ms,
               finished_at: $finished_at
             }]
           | if length > 50 then .[-50:] else . end) as $events
         | {
             schema_version: 1,
             artifact: "ralph_process_cleanup",
             updated_at: $finished_at,
             summary: {
               event_count: ($events | length),
               term_cleanups: ([$events[] | select(.outcome == "term")] | length),
               kill_escalations: ([$events[] | select(.outcome == "kill")] | length),
               already_exited: ([$events[] | select(.outcome == "already_exited")] | length),
               max_duration_ms: ([$events[].duration_ms] | if length > 0 then max else 0 end)
             },
             events: $events
           }' "$file" >"$tmp" 2>/dev/null; then
        chmod 600 "$tmp" 2>/dev/null || true
        if mv -f "$tmp" "$file"; then
            [[ -n "${lock_fd:-}" ]] && exec {lock_fd}>&-
            return 0
        fi
    fi

    rm -f "$tmp"
    [[ -n "${lock_fd:-}" ]] && exec {lock_fd}>&-
    return 1
}

_ralph_process_tree_snapshot() {
    local pid="${1:-}" expected="${2:-}" child child_token
    [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 && -n "$expected" ]] || return 0
    _ralph_process_matches_token "$pid" "$expected" || return 0

    while IFS= read -r child; do
        [[ "$child" =~ ^[0-9]+$ && "$child" -gt 1 ]] || continue
        child_token=$(_ralph_process_start_token "$child" 2>/dev/null || true)
        [[ -n "$child_token" ]] &&
            _ralph_process_tree_snapshot "$child" "$child_token"
    done < <(_ralph_child_pids "$pid")
    printf '%s\t%s\n' "$pid" "$expected"
}

_ralph_terminate_owned_tree() {
    local pid="${1:-}" token="${2:-}" grace="${3:-1}"
    local start_ms finish_ms duration_ms ticks alive=0 idx owned_pid owned_token
    local -a owned_pids=() owned_tokens=()
    _RALPH_LAST_CLEANUP_OUTCOME=already_exited
    _RALPH_LAST_CLEANUP_DURATION_MS=0
    [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]] || return 1
    [[ "$grace" =~ ^[0-9]+$ ]] || grace=1
    [[ "$grace" -le 30 ]] || grace=30

    start_ms=$(_ralph_epoch_ms)
    if _ralph_process_is_running "$pid" "$token"; then
        while IFS=$'\t' read -r owned_pid owned_token; do
            [[ "$owned_pid" =~ ^[0-9]+$ && -n "$owned_token" ]] || continue
            owned_pids+=("$owned_pid")
            owned_tokens+=("$owned_token")
        done < <(_ralph_process_tree_snapshot "$pid" "$token")

        if [[ "${#owned_pids[@]}" -gt 0 ]]; then
            _RALPH_LAST_CLEANUP_OUTCOME=term
            for idx in "${!owned_pids[@]}"; do
                _ralph_process_is_running "${owned_pids[$idx]}" "${owned_tokens[$idx]}" &&
                    kill -TERM "${owned_pids[$idx]}" 2>/dev/null || true
            done

            ticks=$((grace * 10))
            while [[ "$ticks" -gt 0 ]]; do
                alive=0
                for idx in "${!owned_pids[@]}"; do
                    if _ralph_process_is_running "${owned_pids[$idx]}" "${owned_tokens[$idx]}"; then
                        alive=1
                        break
                    fi
                done
                [[ "$alive" -eq 0 ]] && break
                sleep 0.1
                ticks=$((ticks - 1))
            done

            alive=0
            for idx in "${!owned_pids[@]}"; do
                if _ralph_process_is_running "${owned_pids[$idx]}" "${owned_tokens[$idx]}"; then
                    alive=1
                    kill -KILL "${owned_pids[$idx]}" 2>/dev/null || true
                fi
            done
            [[ "$alive" -eq 1 ]] && _RALPH_LAST_CLEANUP_OUTCOME=kill
        fi
    fi

    finish_ms=$(_ralph_epoch_ms)
    duration_ms=$((finish_ms - start_ms))
    [[ "$duration_ms" -ge 0 ]] || duration_ms=0
    _RALPH_LAST_CLEANUP_DURATION_MS="$duration_ms"
    return 0
}

terminate_owned_process() {
    local pid="${1:-}" kind="${2:-provider}" trigger="${3:-exit}" grace="${4:-1}"
    local token="" registered=0 registered_pid
    [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]] || return 1

    for registered_pid in "${RALPH_CHILD_PIDS[@]}"; do
        if [[ "$registered_pid" == "$pid" ]]; then
            registered=1
            token="${RALPH_CHILD_START_TOKENS[$pid]:-}"
            break
        fi
    done
    if [[ "$registered" -eq 0 ]]; then
        token=$(_ralph_process_start_token "$pid" 2>/dev/null || true)
    fi

    _ralph_terminate_owned_tree "$pid" "$token" "$grace"
    _ralph_record_process_cleanup_event "$kind" "$trigger" \
        "${_RALPH_LAST_CLEANUP_OUTCOME:-already_exited}" \
        "${_RALPH_LAST_CLEANUP_DURATION_MS:-0}" || true
    return 0
}

start_child_guardian() {
    local child_pid="${1:-}" owner_pid="${2:-${BASHPID:-$$}}" kind="${3:-provider}"
    local owner_token child_token
    [[ "$child_pid" =~ ^[0-9]+$ && "$owner_pid" =~ ^[0-9]+$ ]] || return 1
    case "$kind" in provider|live_smoke) ;; *) kind=provider ;; esac
    owner_token=$(_ralph_process_start_token "$owner_pid") || return 1
    child_token=$(_ralph_process_start_token "$child_pid") || return 1
    [[ -n "$owner_token" && -n "$child_token" ]] || return 1

    (
        trap - EXIT HUP INT TERM
        # Never let a guardian prolong the singleton lock after Ralph dies.
        { exec 9>&-; } 2>/dev/null || true
        while _ralph_process_matches_token "$child_pid" "$child_token"; do
            if ! _ralph_process_matches_token "$owner_pid" "$owner_token"; then
                _ralph_terminate_owned_tree "$child_pid" "$child_token" 1
                _ralph_record_process_cleanup_event "$kind" parent_death \
                    "${_RALPH_LAST_CLEANUP_OUTCOME:-already_exited}" \
                    "${_RALPH_LAST_CLEANUP_DURATION_MS:-0}" || true
                exit 0
            fi
            sleep 1
        done
    ) >/dev/null 2>&1 &
    _RALPH_LAST_GUARDIAN_PID=$!
    register_child_process "$_RALPH_LAST_GUARDIAN_PID" guardian || true
    return 0
}

stop_child_guardian() {
    local guardian_pid="${1:-}" token
    [[ "$guardian_pid" =~ ^[0-9]+$ ]] || return 0
    token="${RALPH_CHILD_START_TOKENS[$guardian_pid]:-}"
    if [[ -n "$token" ]] && _ralph_process_matches_token "$guardian_pid" "$token"; then
        if _ralph_process_is_running "$guardian_pid" "$token"; then
            kill -TERM "$guardian_pid" 2>/dev/null || true
        fi
        wait "$guardian_pid" 2>/dev/null || true
    fi
    unregister_child_process "$guardian_pid"
}

terminate_registered_processes() {
    local exit_code="${1:-0}" grace="${RALPH_CHILD_TERM_GRACE:-2}" pid kind token trigger=exit
    case "$exit_code" in
        129|130|143) trigger=signal ;;
    esac
    [[ "$grace" =~ ^[0-9]+$ ]] || grace=2
    [[ "$grace" -le 30 ]] || grace=30

    for pid in "${RALPH_CHILD_PIDS[@]}"; do
        kind="${RALPH_CHILD_KINDS[$pid]:-owned}"
        token="${RALPH_CHILD_START_TOKENS[$pid]:-}"
        case "$kind" in
            provider|live_smoke)
                terminate_owned_process "$pid" "$kind" "$trigger" "$grace"
                ;;
            *)
                _ralph_process_is_running "$pid" "$token" &&
                    _ralph_terminate_process_tree TERM "$pid"
                ;;
        esac
    done

    [[ "${#RALPH_CHILD_PIDS[@]}" -gt 0 ]] && sleep 0.1
    for pid in "${RALPH_CHILD_PIDS[@]}"; do
        token="${RALPH_CHILD_START_TOKENS[$pid]:-}"
        if _ralph_process_is_running "$pid" "$token"; then
            _ralph_terminate_process_tree KILL "$pid"
        fi
        wait "$pid" 2>/dev/null || true
    done
    RALPH_CHILD_PIDS=()
    RALPH_CHILD_KINDS=()
    RALPH_CHILD_START_TOKENS=()
}
