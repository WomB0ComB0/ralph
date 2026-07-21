#!/bin/bash
# lib/resources.sh - read-only local resource footprint reporting for Ralph.

_resource_now() { date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s; }

_resource_size_bytes() {
    local path="$1"
    [[ -e "$path" ]] || { printf '0\n'; return 0; }
    du -sb "$path" 2>/dev/null | awk '{print $1}' || printf '0\n'
}

_resource_count_files() {
    local path="$1" pattern="${2:-*}"
    [[ -d "$path" ]] || { printf '0\n'; return 0; }
    find "$path" -maxdepth 1 -type f -name "$pattern" 2>/dev/null | wc -l | tr -d '[:space:]'
}

_resource_count_dirs() {
    local path="$1"
    [[ -d "$path" ]] || { printf '0\n'; return 0; }
    find "$path" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d '[:space:]'
}

_resource_load_json() {
    if [[ -r /proc/loadavg ]]; then
        awk '{printf "{\"load1\":%s,\"load5\":%s,\"load15\":%s}", $1, $2, $3}' /proc/loadavg
    else
        printf '{"load1":null,"load5":null,"load15":null}'
    fi
}

_resource_memory_json() {
    if command -v free >/dev/null 2>&1; then
        free -k | awk '/^Mem:/ {printf "{\"total_kib\":%s,\"used_kib\":%s,\"available_kib\":%s}", $2, $3, $7; found=1} END {if (!found) printf "{\"total_kib\":null,\"used_kib\":null,\"available_kib\":null}"}'
    else
        printf '{"total_kib":null,"used_kib":null,"available_kib":null}'
    fi
}

_resource_timer_json() {
    local out count=0 next=""
    if command -v systemctl >/dev/null 2>&1; then
        out=$(systemctl --user list-timers 'ralph-*' --no-pager 2>/dev/null || true)
        count=$(printf '%s\n' "$out" | awk '/ralph-.*\.timer/ {c++} END {print c+0}')
        next=$(printf '%s\n' "$out" | awk '/ralph-.*\.timer/ {print; exit}')
    fi
    jq -n --argjson count "${count:-0}" --arg next "$next" '{active_timer_count:$count,next_timer:$next}'
}

_resource_synapse_json() {
    local ps_out count=0 rss=0 cpu="0"
    ps_out=$(ps -eo rss=,pcpu=,comm=,args= 2>/dev/null | awk '($3 == "synapse" || $0 ~ /[\/ ]synapse($| )/) {print}' || true)
    if [[ -n "$ps_out" ]]; then
        count=$(printf '%s\n' "$ps_out" | wc -l | tr -d '[:space:]')
        rss=$(printf '%s\n' "$ps_out" | awk '{s += $1} END {print s+0}')
        cpu=$(printf '%s\n' "$ps_out" | awk '{s += $2} END {printf "%.2f", s+0}')
    fi
    jq -n --argjson count "${count:-0}" --argjson rss "${rss:-0}" --argjson cpu "${cpu:-0}" '{process_count:$count,rss_kib:$rss,cpu_percent:$cpu}'
}

handle_resource_report_command() {
    command -v jq >/dev/null 2>&1 || { echo "resource report requires jq" >&2; return 1; }
    local project="${PROJECT_DIR:-$(pwd)}"
    local ralph_dir="${RALPH_DIR:-$project/.ralph}"
    local run_root="${RALPH_RUN_ROOT:-$ralph_dir/runs}"
    local signal_dir="${SIGNAL_DIR:-$ralph_dir/artifacts/signals}"
    local beads_dir="$ralph_dir/beads"
    local state_root="${RALPH_ORG_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/ralph}"
    local config_root="${RALPH_ORG_CONFIG_ROOT:-${XDG_CONFIG_HOME:-$HOME/.config}/ralph}"
    local latest_patrol_log="" latest_patrol_size=0
    latest_patrol_log=$(find "$state_root" -type f -name 'patrol-*.log' -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1 {sub(/^[^ ]+ /, ""); print; exit}' || true)
    [[ -n "$latest_patrol_log" ]] && latest_patrol_size=$(_resource_size_bytes "$latest_patrol_log")

    jq -n \
        --arg artifact "ralph_resource_report" \
        --arg generated_at "$(_resource_now)" \
        --argjson ralph_bytes "$(_resource_size_bytes "$ralph_dir")" \
        --argjson runs_bytes "$(_resource_size_bytes "$run_root")" \
        --argjson signals_bytes "$(_resource_size_bytes "$signal_dir")" \
        --argjson beads_bytes "$(_resource_size_bytes "$beads_dir")" \
        --argjson org_state_bytes "$(_resource_size_bytes "$state_root")" \
        --argjson org_config_bytes "$(_resource_size_bytes "$config_root")" \
        --argjson signal_files "$(_resource_count_files "$signal_dir" '*.json')" \
        --argjson run_dirs "$(_resource_count_dirs "$run_root")" \
        --arg latest_patrol_log "$latest_patrol_log" \
        --argjson latest_patrol_log_bytes "${latest_patrol_size:-0}" \
        --argjson load "$(_resource_load_json)" \
        --argjson memory "$(_resource_memory_json)" \
        --argjson timers "$(_resource_timer_json)" \
        --argjson synapse "$(_resource_synapse_json)" \
        '{schema_version:1, artifact:$artifact, generated_at:$generated_at,
          disk:{ralph_bytes:$ralph_bytes,runs_bytes:$runs_bytes,signals_bytes:$signals_bytes,beads_bytes:$beads_bytes,org_state_bytes:$org_state_bytes,org_config_bytes:$org_config_bytes,signal_files:$signal_files,run_dirs:$run_dirs,latest_patrol_log_bytes:$latest_patrol_log_bytes,latest_patrol_log:(if $latest_patrol_log == "" then null else $latest_patrol_log end)},
          system:{load:$load,memory:$memory,timers:$timers,synapse:$synapse}}'
}

handle_resource_command() {
    case "${1:-report}" in
        report) shift || true; handle_resource_report_command "$@" ;;
        *) echo "Usage: ralph resource report"; return 1 ;;
    esac
}
