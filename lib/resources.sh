#!/bin/bash
# lib/resources.sh - local resource footprint reporting for Ralph.

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

_resource_is_number() { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
_resource_is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }

_resource_parse_bytes() {
    local raw="$1" number unit
    raw="${raw//[[:space:]]/}"
    [[ -n "$raw" ]] || { printf '\n'; return 0; }
    if [[ "$raw" =~ ^([0-9]+)([KkMmGgTt]i?[Bb]?|[Bb])?$ ]]; then
        number="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]}"
        unit="${unit^^}"
        case "$unit" in
            ""|B) printf '%s\n' "$number" ;;
            K|KB|KIB) printf '%s\n' $((number * 1024)) ;;
            M|MB|MIB) printf '%s\n' $((number * 1024 * 1024)) ;;
            G|GB|GIB) printf '%s\n' $((number * 1024 * 1024 * 1024)) ;;
            T|TB|TIB) printf '%s\n' $((number * 1024 * 1024 * 1024 * 1024)) ;;
            *) return 1 ;;
        esac
    else
        return 1
    fi
}

_resource_budget_json_number() {
    [[ -n "${1:-}" ]] && printf '%s\n' "$1" || printf 'null\n'
}

_resource_previous_snapshot() {
    local history_file="$1" line=""
    if [[ -n "$history_file" && -f "$history_file" && ! -L "$history_file" ]]; then
        line=$(tail -n 1 "$history_file" 2>/dev/null || true)
        if [[ -n "$line" ]] && jq -e type >/dev/null 2>&1 <<<"$line"; then
            printf '%s\n' "$line"
            return 0
        fi
    fi
    printf 'null\n'
}

_resource_history_snapshot() {
    jq -c '{schema_version:1, artifact:"ralph_resource_snapshot", generated_at,
            disk:{ralph_bytes:.disk.ralph_bytes,runs_bytes:.disk.runs_bytes,signals_bytes:.disk.signals_bytes,beads_bytes:.disk.beads_bytes,signal_files:.disk.signal_files,run_dirs:.disk.run_dirs},
            system:{load1:.system.load.load1,memory_used_percent:.system.memory.used_percent,synapse_process_count:.system.synapse.process_count,synapse_rss_kib:.system.synapse.rss_kib,synapse_cpu_percent:.system.synapse.cpu_percent},
            ok, warning_count:(.warnings | length)}'
}

_resource_write_history() {
    local history_file="$1" retention="$2" report="$3" dir tmp snapshot
    [[ -n "$history_file" ]] || return 0
    [[ ! -L "$history_file" ]] || { echo "resource history refuses symlink: $history_file" >&2; return 1; }
    dir=$(dirname "$history_file")
    mkdir -p "$dir" || return 1
    snapshot=$(_resource_history_snapshot <<<"$report") || return 1
    tmp=$(mktemp "$dir/.resource-history.XXXXXX") || return 1
    chmod 600 "$tmp" 2>/dev/null || true
    [[ -f "$history_file" ]] && cat "$history_file" >>"$tmp" 2>/dev/null || true
    printf '%s\n' "$snapshot" >>"$tmp"
    if [[ "$retention" -gt 0 ]]; then
        tail -n "$retention" "$tmp" >"$tmp.keep" && mv "$tmp.keep" "$tmp"
    fi
    mv "$tmp" "$history_file"
    chmod 600 "$history_file" 2>/dev/null || true
}

_resource_report_usage() {
    cat <<'EOF'
Usage: ralph resource report [options]

Options:
  --max-load1 N              Warn when 1-minute system load exceeds N.
  --max-memory-used-pct N    Warn when used memory percentage exceeds N.
  --max-ralph-bytes BYTES    Warn when .ralph disk footprint exceeds BYTES. Supports K/M/G/T suffixes.
  --max-run-dirs N           Warn when retained .ralph run directories exceed N.
  --max-growth-pct N         Warn when tracked metrics grew by more than N percent since the last history snapshot.
  --record-history FILE      Append a compact JSONL snapshot after building the report.
  --history-retention N      Keep at most N history snapshots, default 96. Set 0 to keep all.
  --fail-on-warning          Exit 3 after printing JSON if any warning is present.
EOF
}

handle_resource_report_command() {
    command -v jq >/dev/null 2>&1 || { echo "resource report requires jq" >&2; return 1; }
    local max_load1="${RALPH_RESOURCE_MAX_LOAD1:-}"
    local max_memory_pct="${RALPH_RESOURCE_MAX_MEMORY_USED_PCT:-}"
    local max_ralph_bytes="${RALPH_RESOURCE_MAX_RALPH_BYTES:-${RALPH_RESOURCE_MAX_DISK_BYTES:-}}"
    local max_run_dirs="${RALPH_RESOURCE_MAX_RUN_DIRS:-}"
    local max_growth_pct="${RALPH_RESOURCE_MAX_GROWTH_PCT:-}"
    local history_file="${RALPH_RESOURCE_HISTORY_FILE:-}"
    local history_retention="${RALPH_RESOURCE_HISTORY_RETENTION:-96}"
    local fail_on_warning="${RALPH_RESOURCE_FAIL_ON_WARNING:-0}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --max-load1) max_load1="${2:?--max-load1 requires a value}"; shift 2 ;;
            --max-load1=*) max_load1="${1#*=}"; shift ;;
            --max-memory-used-pct) max_memory_pct="${2:?--max-memory-used-pct requires a value}"; shift 2 ;;
            --max-memory-used-pct=*) max_memory_pct="${1#*=}"; shift ;;
            --max-ralph-bytes|--max-disk-bytes) max_ralph_bytes="${2:?$1 requires a value}"; shift 2 ;;
            --max-ralph-bytes=*|--max-disk-bytes=*) max_ralph_bytes="${1#*=}"; shift ;;
            --max-run-dirs) max_run_dirs="${2:?--max-run-dirs requires a value}"; shift 2 ;;
            --max-run-dirs=*) max_run_dirs="${1#*=}"; shift ;;
            --max-growth-pct) max_growth_pct="${2:?--max-growth-pct requires a value}"; shift 2 ;;
            --max-growth-pct=*) max_growth_pct="${1#*=}"; shift ;;
            --record-history|--history-file) history_file="${2:?$1 requires a value}"; shift 2 ;;
            --record-history=*|--history-file=*) history_file="${1#*=}"; shift ;;
            --history-retention) history_retention="${2:?--history-retention requires a value}"; shift 2 ;;
            --history-retention=*) history_retention="${1#*=}"; shift ;;
            --fail-on-warning) fail_on_warning=1; shift ;;
            -h|--help) _resource_report_usage; return 0 ;;
            *) echo "unknown resource report argument: $1" >&2; _resource_report_usage >&2; return 2 ;;
        esac
    done

    if [[ -n "$max_load1" ]] && ! _resource_is_number "$max_load1"; then
        echo "invalid --max-load1: $max_load1" >&2
        return 2
    fi
    if [[ -n "$max_memory_pct" ]] && ! _resource_is_number "$max_memory_pct"; then
        echo "invalid --max-memory-used-pct: $max_memory_pct" >&2
        return 2
    fi
    if [[ -n "$max_run_dirs" ]] && ! _resource_is_int "$max_run_dirs"; then
        echo "invalid --max-run-dirs: $max_run_dirs" >&2
        return 2
    fi
    if [[ -n "$max_growth_pct" ]] && ! _resource_is_number "$max_growth_pct"; then
        echo "invalid --max-growth-pct: $max_growth_pct" >&2
        return 2
    fi
    if ! _resource_is_int "$history_retention"; then
        echo "invalid --history-retention: $history_retention" >&2
        return 2
    fi
    if [[ -n "$max_ralph_bytes" ]]; then
        max_ralph_bytes=$(_resource_parse_bytes "$max_ralph_bytes") || {
            echo "invalid --max-ralph-bytes: $max_ralph_bytes" >&2
            return 2
        }
    fi

    local project="${PROJECT_DIR:-$(pwd)}"
    local ralph_dir="${RALPH_DIR:-$project/.ralph}"
    local run_root="${RALPH_RUN_ROOT:-$ralph_dir/runs}"
    local signal_dir="${SIGNAL_DIR:-$ralph_dir/artifacts/signals}"
    local beads_dir="$ralph_dir/beads"
    local state_root="${RALPH_ORG_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/ralph}"
    local config_root="${RALPH_ORG_CONFIG_ROOT:-${XDG_CONFIG_HOME:-$HOME/.config}/ralph}"
    local latest_patrol_log="" latest_patrol_size=0 report="" previous="" history_recorded=false history_error=""
    latest_patrol_log=$(find "$state_root" -type f -name 'patrol-*.log' -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1 {sub(/^[^ ]+ /, ""); print; exit}' || true)
    [[ -n "$latest_patrol_log" ]] && latest_patrol_size=$(_resource_size_bytes "$latest_patrol_log")
    previous=$(_resource_previous_snapshot "$history_file")

    # Self-benchmarking: next, add slope-based trend warnings instead of only comparing to the previous snapshot.
    report=$(jq -n \
        --arg artifact "ralph_resource_report" \
        --arg generated_at "$(_resource_now)" \
        --arg history_file "$history_file" \
        --argjson history_retention "$history_retention" \
        --argjson previous "$previous" \
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
        --argjson max_load1 "$(_resource_budget_json_number "$max_load1")" \
        --argjson max_memory_pct "$(_resource_budget_json_number "$max_memory_pct")" \
        --argjson max_ralph_bytes "$(_resource_budget_json_number "$max_ralph_bytes")" \
        --argjson max_run_dirs "$(_resource_budget_json_number "$max_run_dirs")" \
        --argjson max_growth_pct "$(_resource_budget_json_number "$max_growth_pct")" \
        'def warn($kind;$metric;$observed;$limit;$message): {kind:$kind,metric:$metric,observed:$observed,limit:$limit,message:$message};
         def pct_growth($current;$old): if $current == null or $old == null or $old <= 0 then null else ((($current - $old) / $old * 10000 | round) / 100) end;
         def delta($current;$old): if $current == null or $old == null then null else $current - $old end;
         {schema_version:1, artifact:$artifact, generated_at:$generated_at,
          disk:{ralph_bytes:$ralph_bytes,runs_bytes:$runs_bytes,signals_bytes:$signals_bytes,beads_bytes:$beads_bytes,org_state_bytes:$org_state_bytes,org_config_bytes:$org_config_bytes,signal_files:$signal_files,run_dirs:$run_dirs,latest_patrol_log_bytes:$latest_patrol_log_bytes,latest_patrol_log:(if $latest_patrol_log == "" then null else $latest_patrol_log end)},
          system:{load:$load,memory:$memory,timers:$timers,synapse:$synapse},
          budgets:{max_load1:$max_load1,max_memory_used_percent:$max_memory_pct,max_ralph_bytes:$max_ralph_bytes,max_run_dirs:$max_run_dirs,max_growth_percent:$max_growth_pct},
          history:{file:(if $history_file == "" then null else $history_file end), retention:$history_retention, recorded:false, error:null}}
         | .system.memory.used_percent = (if .system.memory.total_kib != null and .system.memory.total_kib > 0 then ((.system.memory.used_kib / .system.memory.total_kib * 10000 | round) / 100) else null end)
         | .trend = (if $previous == null then {previous_at:null,deltas:{},growth_percent:{}} else {
             previous_at:$previous.generated_at,
             deltas:{ralph_bytes:delta(.disk.ralph_bytes;$previous.disk.ralph_bytes),run_dirs:delta(.disk.run_dirs;$previous.disk.run_dirs),load1:delta(.system.load.load1;$previous.system.load1),memory_used_percent:delta(.system.memory.used_percent;$previous.system.memory_used_percent)},
             growth_percent:{ralph_bytes:pct_growth(.disk.ralph_bytes;$previous.disk.ralph_bytes),run_dirs:pct_growth(.disk.run_dirs;$previous.disk.run_dirs),load1:pct_growth(.system.load.load1;$previous.system.load1),memory_used_percent:pct_growth(.system.memory.used_percent;$previous.system.memory_used_percent)}
           } end)
         | .warnings = [
             if .budgets.max_load1 != null and .system.load.load1 != null and .system.load.load1 > .budgets.max_load1 then warn("cpu";"system.load.load1";.system.load.load1;.budgets.max_load1;"1-minute system load exceeds budget") else empty end,
             if .budgets.max_memory_used_percent != null and .system.memory.used_percent != null and .system.memory.used_percent > .budgets.max_memory_used_percent then warn("memory";"system.memory.used_percent";.system.memory.used_percent;.budgets.max_memory_used_percent;"used memory percentage exceeds budget") else empty end,
             if .budgets.max_ralph_bytes != null and .disk.ralph_bytes > .budgets.max_ralph_bytes then warn("disk";"disk.ralph_bytes";.disk.ralph_bytes;.budgets.max_ralph_bytes;"Ralph disk footprint exceeds budget") else empty end,
             if .budgets.max_run_dirs != null and .disk.run_dirs > .budgets.max_run_dirs then warn("runs";"disk.run_dirs";.disk.run_dirs;.budgets.max_run_dirs;"retained run directory count exceeds budget") else empty end,
             if .budgets.max_growth_percent != null and .trend.growth_percent.ralph_bytes != null and .trend.growth_percent.ralph_bytes > .budgets.max_growth_percent then warn("trend";"trend.growth_percent.ralph_bytes";.trend.growth_percent.ralph_bytes;.budgets.max_growth_percent;"Ralph disk footprint growth exceeds trend budget") else empty end,
             if .budgets.max_growth_percent != null and .trend.growth_percent.run_dirs != null and .trend.growth_percent.run_dirs > .budgets.max_growth_percent then warn("trend";"trend.growth_percent.run_dirs";.trend.growth_percent.run_dirs;.budgets.max_growth_percent;"retained run directory growth exceeds trend budget") else empty end,
             if .budgets.max_growth_percent != null and .trend.growth_percent.memory_used_percent != null and .trend.growth_percent.memory_used_percent > .budgets.max_growth_percent then warn("trend";"trend.growth_percent.memory_used_percent";.trend.growth_percent.memory_used_percent;.budgets.max_growth_percent;"used memory percentage growth exceeds trend budget") else empty end
           ]
         | .ok = (.warnings | length == 0)') || return 1

    if [[ -n "$history_file" ]]; then
        if _resource_write_history "$history_file" "$history_retention" "$report"; then
            history_recorded=true
        else
            history_error="failed to write resource history"
            echo "WARNING: $history_error: $history_file" >&2
        fi
        report=$(jq --argjson recorded "$history_recorded" --arg err "$history_error" '.history.recorded=$recorded | .history.error=(if $err == "" then null else $err end)' <<<"$report") || return 1
    fi

    printf '%s\n' "$report"
    if [[ "$fail_on_warning" == "1" ]] && jq -e '.ok == false' >/dev/null <<<"$report"; then
        return 3
    fi
    return 0
}

handle_resource_command() {
    case "${1:-report}" in
        report) shift || true; handle_resource_report_command "$@" ;;
        *) echo "Usage: ralph resource report"; return 1 ;;
    esac
}
