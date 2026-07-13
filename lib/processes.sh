#!/bin/bash

# Background process ownership for one Ralph shell. PIDs are kept in memory so
# read-only commands and separate Ralph invocations never share cleanup state.
declare -a RALPH_CHILD_PIDS=()

register_child_process() {
    local pid="${1:-}" existing
    [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]] || return 1
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
}

_ralph_child_pids() {
    local parent="${1:-}"
    [[ "$parent" =~ ^[0-9]+$ ]] || return 0
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -P "$parent" 2>/dev/null || true
    elif command -v ps >/dev/null 2>&1; then
        ps -eo pid=,ppid= 2>/dev/null |
            awk -v parent="$parent" '$2 == parent { print $1 }'
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

start_child_guardian() {
    local child_pid="${1:-}" owner_pid="${2:-${BASHPID:-$$}}" owner_token child_token
    [[ "$child_pid" =~ ^[0-9]+$ && "$owner_pid" =~ ^[0-9]+$ ]] || return 1
    owner_token=$(_ralph_process_start_token "$owner_pid") || return 1
    child_token=$(_ralph_process_start_token "$child_pid") || return 1
    [[ -n "$owner_token" && -n "$child_token" ]] || return 1

    (
        trap - EXIT HUP INT TERM
        # Never let a guardian prolong the singleton lock after Ralph dies.
        { exec 9>&-; } 2>/dev/null || true
        while [[ "$(_ralph_process_start_token "$child_pid" 2>/dev/null || true)" == "$child_token" ]]; do
            if [[ "$(_ralph_process_start_token "$owner_pid" 2>/dev/null || true)" != "$owner_token" ]]; then
                _ralph_terminate_process_tree TERM "$child_pid"
                sleep 1
                if [[ "$(_ralph_process_start_token "$child_pid" 2>/dev/null || true)" == "$child_token" ]]; then
                    _ralph_terminate_process_tree KILL "$child_pid"
                fi
                exit 0
            fi
            sleep 1
        done
    ) >/dev/null 2>&1 &
    _RALPH_LAST_GUARDIAN_PID=$!
    register_child_process "$_RALPH_LAST_GUARDIAN_PID" || true
    return 0
}

stop_child_guardian() {
    local guardian_pid="${1:-}"
    [[ "$guardian_pid" =~ ^[0-9]+$ ]] || return 0
    kill -TERM "$guardian_pid" 2>/dev/null || true
    wait "$guardian_pid" 2>/dev/null || true
    unregister_child_process "$guardian_pid"
}

# Self-benchmarking: next, record cleanup latency and TERM-to-KILL escalation in
# run evidence so operators can detect providers that degrade during shutdown.
terminate_registered_processes() {
    local grace="${RALPH_CHILD_TERM_GRACE:-2}" ticks pid alive
    [[ "$grace" =~ ^[0-9]+$ ]] || grace=2
    [[ "$grace" -le 30 ]] || grace=30

    for pid in "${RALPH_CHILD_PIDS[@]}"; do
        kill -0 "$pid" 2>/dev/null && _ralph_terminate_process_tree TERM "$pid"
    done

    ticks=$((grace * 10))
    while [[ "$ticks" -gt 0 ]]; do
        alive=0
        for pid in "${RALPH_CHILD_PIDS[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                alive=1
                break
            fi
        done
        [[ "$alive" -eq 0 ]] && break
        sleep 0.1
        ticks=$((ticks - 1))
    done

    for pid in "${RALPH_CHILD_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            _ralph_terminate_process_tree KILL "$pid"
        fi
        wait "$pid" 2>/dev/null || true
    done
    RALPH_CHILD_PIDS=()
}
