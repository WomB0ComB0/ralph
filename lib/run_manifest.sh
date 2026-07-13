#!/bin/bash

# Durable run lifecycle evidence. This module intentionally serializes only an
# allowlist of operational metadata, never environment variables or prompt data.

run_manifest_file() {
    printf '%s/run.json\n' "${RUN_DIR:-${_RALPH_DIR:-.ralph}/runs/${RUN_ID:-manual}}"
}

_run_manifest_now() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

_run_manifest_number() {
    local value="${1:-0}"
    [[ "$value" =~ ^[0-9]+$ ]] && printf '%s\n' "$value" || printf '0\n'
}

_run_manifest_bool() {
    case "${1:-false}" in
        1|true|TRUE|yes|YES) printf 'true\n' ;;
        *)                   printf 'false\n' ;;
    esac
}

_run_manifest_replace() {
    local file="$1"
    shift
    local tmp lock_file lock_fd lock_wait=3
    lock_file="${file}.lock"
    if command -v flock >/dev/null 2>&1; then
        lock_wait="${RALPH_LOCK_WAIT_SECONDS:-3}"
        [[ "$lock_wait" =~ ^[0-9]+$ ]] || lock_wait=3
        [[ "$lock_wait" -le 60 ]] || lock_wait=60
        if ! { exec {lock_fd}>"$lock_file"; } 2>/dev/null; then
            return 1
        fi
        chmod 600 "$lock_file" 2>/dev/null || true
        if ! flock -w "$lock_wait" "$lock_fd"; then
            exec {lock_fd}>&-
            return 1
        fi
    fi

    tmp=$(mktemp "$(dirname "$file")/.run.json.tmp.XXXXXX") || {
        [[ -n "${lock_fd:-}" ]] && exec {lock_fd}>&-
        return 1
    }
    if jq "$@" "$file" >"$tmp" 2>/dev/null; then
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

reconcile_previous_run_manifest() {
    local previous_run_id="${1:-}" current_run_id="${2:-${RUN_ID:-}}"
    [[ "$previous_run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 0
    [[ "$previous_run_id" != "$current_run_id" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0

    local file="${_RALPH_DIR:-.ralph}/runs/$previous_run_id/run.json"
    [[ -f "$file" ]] || return 0

    local now
    now=$(_run_manifest_now)
    _run_manifest_replace "$file" \
        --arg now "$now" \
        --arg current "$current_run_id" \
        'if (.status == "initializing" or .status == "running") then
            .status = "interrupted"
            | .reason = "unclean_exit_detected"
            | .phase = "terminal"
            | .updated_at = $now
            | .finished_at = $now
            | .exit_code = null
            | .clean_exit = false
            | .recovered_by_run_id = $current
         else . end'
}

init_run_manifest() {
    command -v jq >/dev/null 2>&1 || {
        log_warning "jq unavailable; durable run manifest disabled"
        return 1
    }
    [[ -n "${RUN_DIR:-}" && -n "${RUN_ID:-}" ]] || return 1

    local file state_dir last_id_file previous_run_id="" now epoch tmp id_tmp
    local git_branch="" git_head="" host sandboxed=false
    local unattended interactive run_once resume_requested
    local max_iterations max_tokens max_seconds max_lazy
    file=$(run_manifest_file)
    state_dir="${STATE_DIR:-${_RALPH_DIR:-.ralph}/state}"
    last_id_file="$state_dir/last-run-id"
    [[ -f "$last_id_file" ]] && previous_run_id=$(head -n 1 "$last_id_file" 2>/dev/null || true)

    reconcile_previous_run_manifest "$previous_run_id" "$RUN_ID" || true

    mkdir -p "$(dirname "$file")" "$state_dir" 2>/dev/null || return 1
    now=$(_run_manifest_now)
    epoch=$(date +%s)
    git_branch=$(git -C "${PROJECT_DIR:-.}" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    git_head=$(git -C "${PROJECT_DIR:-.}" rev-parse --verify HEAD 2>/dev/null || true)
    host="${HOSTNAME:-unknown}"
    if declare -F running_in_container >/dev/null 2>&1 && running_in_container; then
        sandboxed=true
    else
        sandboxed=$(_run_manifest_bool "${SANDBOX_MODE:-false}")
    fi
    unattended=$(_run_manifest_bool "${UNATTENDED:-false}")
    interactive=$(_run_manifest_bool "${INTERACTIVE_MODE:-false}")
    run_once=$(_run_manifest_bool "${RUN_ONCE:-false}")
    resume_requested=$(_run_manifest_bool "${RESUME_FLAG:-false}")
    max_iterations=$(_run_manifest_number "${MAX_ITERATIONS:-0}")
    max_tokens=$(_run_manifest_number "${RALPH_MAX_RUN_TOKENS:-0}")
    max_seconds=$(_run_manifest_number "${RALPH_MAX_RUN_SECONDS:-0}")
    max_lazy=$(_run_manifest_number "${RALPH_MAX_LAZY_STREAK:-0}")

    tmp=$(mktemp "$(dirname "$file")/.run.json.tmp.XXXXXX") || return 1
    if ! jq -n \
        --arg run_id "$RUN_ID" \
        --arg project_dir "${PROJECT_DIR:-$(pwd)}" \
        --arg host "$host" \
        --argjson pid "$$" \
        --arg started_at "$now" \
        --argjson started_at_epoch "$epoch" \
        --arg tool "${TOOL:-}" \
        --arg model "${SELECTED_MODEL:-}" \
        --argjson sandboxed "$sandboxed" \
        --argjson unattended "$unattended" \
        --argjson interactive "$interactive" \
        --argjson run_once "$run_once" \
        --argjson max_iterations "$max_iterations" \
        --argjson max_tokens "$max_tokens" \
        --argjson max_seconds "$max_seconds" \
        --argjson max_lazy "$max_lazy" \
        --argjson resume_requested "$resume_requested" \
        --arg previous_run_id "$previous_run_id" \
        --arg git_branch "$git_branch" \
        --arg git_head "$git_head" \
        '{
          schema_version: 1,
          run_id: $run_id,
          status: "initializing",
          reason: null,
          phase: "bootstrap",
          pid: $pid,
          host: $host,
          project_dir: $project_dir,
          started_at: $started_at,
          started_at_epoch: $started_at_epoch,
          updated_at: $started_at,
          heartbeat_at: $started_at,
          heartbeat_sequence: 0,
          finished_at: null,
          duration_seconds: null,
          exit_code: null,
          clean_exit: null,
          current_iteration: 0,
          execution: {
            tool: $tool,
            model: $model,
            sandboxed: $sandboxed,
            unattended: $unattended,
            interactive: $interactive,
            run_once: $run_once
          },
          limits: {
            max_iterations: $max_iterations,
            max_tokens: $max_tokens,
            max_seconds: $max_seconds,
            max_lazy_streak: $max_lazy
          },
          resume: {
            requested: $resume_requested,
            checkpoint_iteration: 0,
            previous_run_id: (if $resume_requested and ($previous_run_id | length > 0) then $previous_run_id else null end)
          },
          git: {
            branch: (if ($git_branch | length) > 0 then $git_branch else null end),
            head: (if ($git_head | length) > 0 then $git_head else null end)
          },
          progress: {
            tokens_total: 0,
            lazy_streak: 0,
            last_verify_ok: false
          }
        }' >"$tmp" 2>/dev/null; then
        rm -f "$tmp"
        log_warning "Failed to create durable run manifest"
        return 1
    fi

    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$file"

    id_tmp=$(mktemp "$state_dir/.last-run-id.tmp.XXXXXX") || return 1
    printf '%s\n' "$RUN_ID" >"$id_tmp"
    chmod 600 "$id_tmp" 2>/dev/null || true
    mv -f "$id_tmp" "$last_id_file"

    _RALPH_RUN_ACTIVE=1
    _RALPH_RUN_FINALIZED=0
    _RALPH_RUN_STARTED_EPOCH="$epoch"
    _RALPH_RUN_PHASE="bootstrap"
    _RALPH_MANIFEST_LAST_HEARTBEAT="$epoch"
    _RALPH_CURRENT_ITERATION=0
    _RALPH_RUN_OUTCOME_STATUS=""
    _RALPH_RUN_OUTCOME_REASON=""
    return 0
}

run_manifest_heartbeat() {
    local phase="${1:-running}" iteration="${2:-${_RALPH_CURRENT_ITERATION:-0}}" force="${3:-0}"
    [[ "${_RALPH_RUN_ACTIVE:-0}" == "1" && "${_RALPH_RUN_FINALIZED:-0}" != "1" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0

    local file now epoch interval elapsed tokens lazy verify_ok resume_checkpoint
    file=$(run_manifest_file)
    [[ -f "$file" ]] || return 0
    epoch=$(date +%s)
    interval=$(_run_manifest_number "${RALPH_RUN_HEARTBEAT_INTERVAL:-15}")
    [[ "$interval" -gt 0 ]] || interval=15
    elapsed=$(( epoch - ${_RALPH_MANIFEST_LAST_HEARTBEAT:-0} ))
    if [[ "$force" != "1" && "$phase" == "${_RALPH_RUN_PHASE:-}" && "$elapsed" -lt "$interval" ]]; then
        return 0
    fi

    iteration=$(_run_manifest_number "$iteration")
    tokens=$(_run_manifest_number "${RUN_TOKENS_TOTAL:-0}")
    lazy=$(_run_manifest_number "${LAZY_STREAK:-0}")
    verify_ok=$(_run_manifest_bool "${LAST_VERIFY_OK:-false}")
    resume_checkpoint=$(_run_manifest_number "${_RALPH_RESUME_CHECKPOINT:-0}")
    now=$(_run_manifest_now)
    if _run_manifest_replace "$file" \
        --arg now "$now" \
        --arg phase "$phase" \
        --arg model "${_RALPH_ACTIVE_MODEL:-${SELECTED_MODEL:-}}" \
        --argjson iteration "$iteration" \
        --argjson tokens "$tokens" \
        --argjson lazy "$lazy" \
        --argjson verify_ok "$verify_ok" \
        --argjson resume_checkpoint "$resume_checkpoint" \
        '.heartbeat_sequence = ((.heartbeat_sequence // 0) + 1)
         | .status = "running"
         | .phase = $phase
         | .updated_at = $now
         | .heartbeat_at = $now
         | .current_iteration = $iteration
         | .execution.model = $model
         | .resume.checkpoint_iteration = $resume_checkpoint
         | .progress.tokens_total = $tokens
         | .progress.lazy_streak = $lazy
         | .progress.last_verify_ok = $verify_ok'; then
        _RALPH_MANIFEST_LAST_HEARTBEAT="$epoch"
        _RALPH_RUN_PHASE="$phase"
        _RALPH_CURRENT_ITERATION="$iteration"
        return 0
    fi
    return 1
}

set_run_outcome() {
    local status="${1:-}" reason="${2:-}"
    case "$status" in
        completed|paused|incomplete|failed|interrupted) ;;
        *) return 1 ;;
    esac
    _RALPH_RUN_OUTCOME_STATUS="$status"
    _RALPH_RUN_OUTCOME_REASON="$reason"
    return 0
}

finalize_run_manifest() {
    local exit_code="${1:-0}"
    [[ "${_RALPH_RUN_ACTIVE:-0}" == "1" && "${_RALPH_RUN_FINALIZED:-0}" != "1" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0

    _RALPH_RUN_FINALIZED=1
    local file status reason now epoch duration iteration tokens lazy verify_ok
    file=$(run_manifest_file)
    [[ -f "$file" ]] || {
        _RALPH_RUN_ACTIVE=0
        return 0
    }
    [[ "$exit_code" =~ ^[0-9]+$ ]] || exit_code=1
    status="${_RALPH_RUN_OUTCOME_STATUS:-}"
    reason="${_RALPH_RUN_OUTCOME_REASON:-}"
    if [[ -z "$status" ]]; then
        if [[ "$exit_code" -eq 0 ]]; then
            status="completed"
            reason="process_exit"
        else
            status="failed"
            reason="unexpected_exit"
        fi
    fi
    [[ -n "$reason" ]] || reason="unspecified"

    now=$(_run_manifest_now)
    epoch=$(date +%s)
    duration=$(( epoch - ${_RALPH_RUN_STARTED_EPOCH:-$epoch} ))
    [[ "$duration" -ge 0 ]] || duration=0
    iteration=$(_run_manifest_number "${_RALPH_CURRENT_ITERATION:-0}")
    tokens=$(_run_manifest_number "${RUN_TOKENS_TOTAL:-0}")
    lazy=$(_run_manifest_number "${LAZY_STREAK:-0}")
    verify_ok=$(_run_manifest_bool "${LAST_VERIFY_OK:-false}")

    if _run_manifest_replace "$file" \
        --arg status "$status" \
        --arg reason "$reason" \
        --arg now "$now" \
        --arg model "${_RALPH_ACTIVE_MODEL:-${SELECTED_MODEL:-}}" \
        --argjson exit_code "$exit_code" \
        --argjson duration "$duration" \
        --argjson iteration "$iteration" \
        --argjson tokens "$tokens" \
        --argjson lazy "$lazy" \
        --argjson verify_ok "$verify_ok" \
        '.status = $status
         | .reason = $reason
         | .phase = "terminal"
         | .updated_at = $now
         | .heartbeat_at = $now
         | .finished_at = $now
         | .duration_seconds = $duration
         | .exit_code = $exit_code
         | .clean_exit = true
         | .current_iteration = $iteration
         | .execution.model = $model
         | .progress.tokens_total = $tokens
         | .progress.lazy_streak = $lazy
         | .progress.last_verify_ok = $verify_ok'; then
        _RALPH_RUN_ACTIVE=0
        return 0
    fi

    _RALPH_RUN_ACTIVE=0
    return 1
}
