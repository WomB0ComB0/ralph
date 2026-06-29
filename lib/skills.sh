#!/bin/bash
# shellcheck disable=SC2154
#######################################
# Guarded skill-authoring layer (built on the signals layer).
#
# A "skill" is a PROVEN RESOLUTION for a recurring problem: keyed by a signal
# theme_key, it captures "when you hit theme X, here's what fixed it". Skills are
# authored automatically when a recurring signal is resolved with a note, start
# as `candidate` (GUARDED — never surfaced until approved), and once approved are
# surfaced into the prompt whenever a matching signal is currently open. Stored one
# JSON per skill under $SKILL_DIR; atomic writes; no-op without jq. Reuses
# _signal_now / _signal_csv_to_json from lib/signals.sh.
#######################################

init_skills() {
    mkdir -p "${SKILL_DIR:-.ralph/artifacts/skills}" 2>/dev/null || true
}

_skill_now() {
    if declare -F _signal_now >/dev/null; then _signal_now; else date -u +%Y-%m-%dT%H:%M:%SZ; fi
}

#######################################
# Create (candidate) or update a skill keyed by a signal theme_key.
# Status is NOT changed on update (an approved skill stays approved).
# Arguments: $1 theme_key, $2 problem, $3 resolution, [$4 tags_csv]
# Returns: echoes the theme_key
#######################################
record_skill() {
    command_exists jq || return 0
    local theme="$1" problem="$2" resolution="$3" tags_csv="${4:-}"
    [[ -n "$theme" ]] || return 0

    local dir="${SKILL_DIR:-.ralph/artifacts/skills}"
    mkdir -p "$dir" 2>/dev/null || true
    local file="$dir/$theme.json"
    local now run tags_json tmp
    now=$(_skill_now); run="${RUN_ID:-unknown}"
    if declare -F _signal_csv_to_json >/dev/null; then
        tags_json=$(_signal_csv_to_json "$tags_csv")
    else
        tags_json='[]'
    fi
    tmp=$(mktemp "$dir/.skill.XXXXXX" 2>/dev/null) || tmp=$(mktemp) || return 1

    if [[ -f "$file" ]]; then
        if jq --arg res "$resolution" --arg prob "$problem" --arg now "$now" --arg run "$run" --argjson tags "$tags_json" \
              '.resolution = (if ($res == "" or .status == "approved") then .resolution else $res end)
               | .problem = (if ($prob == "" or .status == "approved") then .problem else $prob end)
               | .updated_at = $now | .last_run = $run
               | .tags = (((.tags // []) + $tags) | unique)' \
              "$file" > "$tmp" 2>/dev/null; then
            mv -f "$tmp" "$file" || log_warning "record_skill: failed to write $file"
        fi
    else
        if jq -n --arg theme "$theme" --arg prob "$problem" --arg res "$resolution" \
              --arg now "$now" --arg run "$run" --argjson tags "$tags_json" \
              '{schema_version: 1, theme_key: $theme, problem: $prob, resolution: $res,
                status: "candidate", tags: $tags, uses: 0,
                created_at: $now, updated_at: $now, approved_at: null,
                first_run: $run, last_run: $run}' \
              > "$tmp" 2>/dev/null; then
            mv -f "$tmp" "$file" || log_warning "record_skill: failed to write $file"
        fi
    fi
    rm -f "$tmp" 2>/dev/null
    printf '%s\n' "$theme"
}

# Internal: atomic jq mutation of one skill file.
_skill_set() {
    local theme="$1"; shift
    command_exists jq || return 0
    local file="${SKILL_DIR:-.ralph/artifacts/skills}/$theme.json"
    [[ -f "$file" ]] || return 1
    local tmp; tmp=$(mktemp "$(dirname "$file")/.skill.XXXXXX" 2>/dev/null) || tmp=$(mktemp) || return 1
    if jq "$@" "$file" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$file"
    else
        rm -f "$tmp"; return 1
    fi
}

approve_skill() { _skill_set "$1" --arg n "$(_skill_now)" '.status = "approved" | .approved_at = $n'; }
reject_skill()  { _skill_set "$1" '.status = "rejected"'; }

skill_get() {
    local f="${SKILL_DIR:-.ralph/artifacts/skills}/$1.json"
    [[ -f "$f" ]] && cat "$f"
}

#######################################
# Auto-author a candidate skill when a recurring signal is resolved with a note.
# Arguments: $1 signal theme_key, $2 resolve note
#######################################
_skill_autocapture() {
    command_exists jq || return 0
    local key="$1" note="$2"
    [[ -n "$note" ]] || return 0
    # Synthetic notes from _signal_auto_resolve_family are not proven resolutions.
    case "$note" in auto-resolved:*) return 0 ;; esac
    local sigfile="${SIGNAL_DIR:-.ralph/artifacts/signals}/$key.json"
    [[ -f "$sigfile" ]] || return 0

    local freq obs tags
    freq=$(jq -r '.frequency // 0' "$sigfile" 2>/dev/null)
    [[ "$freq" =~ ^[0-9]+$ ]] || freq=0
    [[ $freq -ge ${RALPH_SKILL_MIN_FREQ:-2} ]] || return 0
    obs=$(jq -r '.observation // ""' "$sigfile" 2>/dev/null)
    tags=$(jq -r '(.tags // []) | join(",")' "$sigfile" 2>/dev/null)
    record_skill "$key" "$obs" "$note" "$tags" >/dev/null
}

#######################################
# Surface APPROVED skills whose theme matches a currently-OPEN signal.
# Arguments: [$1 limit]
#######################################
recall_skills() {
    command_exists jq || return 0
    local limit="${1:-${RALPH_SKILL_RECALL:-5}}"
    [[ "$limit" =~ ^[0-9]+$ ]] || limit=5
    local sdir="${SIGNAL_DIR:-.ralph/artifacts/signals}"
    local kdir="${SKILL_DIR:-.ralph/artifacts/skills}"
    local gdir="${RALPH_GLOBAL_SKILL_DIR:-${HOME:-}/.config/ralph/skills}"
    [[ -d "$sdir" ]] || return 0

    local tmpf sf sstatus theme skillfile pst gst src suffix sev freq rank
    tmpf=$(mktemp) || return 0
    for sf in "$sdir"/*.json; do
        [[ -f "$sf" ]] || continue
        sstatus=$(jq -r '.status // ""' "$sf" 2>/dev/null) || continue
        [[ "$sstatus" == "open" || "$sstatus" == "ack" ]] || continue
        theme=$(jq -r '.theme_key // ""' "$sf" 2>/dev/null) || continue
        [[ -n "$theme" ]] || continue
        # Prefer a project-local APPROVED skill; otherwise fall back to a globalized
        # one (global skills are pre-vetted — only approved skills can be globalized).
        skillfile="$kdir/$theme.json"
        src=""; suffix=""
        if [[ -f "$skillfile" ]]; then
            # A local skill is authoritative for this repo: surface it only if approved;
            # a candidate/rejected local skill SUPPRESSES the global fallback (the local
            # decision — including an explicit reject — must win).
            pst=$(jq -r '.status // ""' "$skillfile" 2>/dev/null) || pst=""
            [[ "$pst" == "approved" ]] && src="$skillfile"
        elif [[ -f "$gdir/$theme.json" ]]; then
            # No local skill: fall back to a global one, but verify it is itself approved
            # (don't trust a hand-edited / older-format / since-rejected global file).
            gst=$(jq -r '.status // ""' "$gdir/$theme.json" 2>/dev/null) || gst=""
            [[ "$gst" == "approved" ]] && { src="$gdir/$theme.json"; suffix=" (cross-project fix)"; }
        fi
        [[ -n "$src" ]] || continue
        # Rank by the matching signal's severity then frequency so the most urgent
        # problem's fix wins the bounded slots (not alphabetical glob order).
        sev=$(jq -r '.severity // "low"' "$sf" 2>/dev/null) || sev=low
        freq=$(jq -r '.frequency // 0' "$sf" 2>/dev/null) || freq=0
        [[ "$freq" =~ ^[0-9]+$ ]] || freq=0
        case "$sev" in high) rank=3 ;; medium) rank=2 ;; *) rank=1 ;; esac
        printf '%d%06d\t- %s%s\n' "$rank" "$freq" "$(jq -r '.theme_key + ": " + .resolution' "$src" 2>/dev/null)" "$suffix" >> "$tmpf" || true
    done
    local lines
    lines=$(sort -rn "$tmpf" 2>/dev/null | head -n "$limit" | cut -f2-)
    rm -f "$tmpf"
    [[ -z "$lines" ]] && return 0
    printf '\n<skills>\nProven resolutions for problems you are currently hitting (apply these):\n%s\n</skills>\n' "$lines"
}

#######################################
# Human-readable skill table (CLI).
# Arguments: [$1 status filter]
#######################################
list_skills() {
    command_exists jq || { echo "jq required"; return 0; }
    local filter="${1:-}"
    local dir="${SKILL_DIR:-.ralph/artifacts/skills}"
    [[ -d "$dir" ]] || { echo "No skills."; return 0; }
    local f st any=0
    for f in "$dir"/*.json; do
        [[ -f "$f" ]] || continue
        st=$(jq -r '.status // ""' "$f" 2>/dev/null) || continue
        [[ -n "$filter" && "$st" != "$filter" ]] && continue
        jq -r '"[\(.status)] \(.theme_key) — \(.resolution)"' "$f" 2>/dev/null || continue
        any=1
    done
    [[ $any -eq 0 ]] && echo "No skills."
    return 0
}

#######################################
# Archive rejected skills and stale (idle past TTL) candidates; approved skills
# are kept forever. Mirrors prune_signals.
# Arguments: [$1 ttl_days]
#######################################
prune_skills() {
    command_exists jq || return 0
    local dir="${SKILL_DIR:-.ralph/artifacts/skills}"
    local archive="$dir/.archive"
    [[ -d "$dir" ]] || return 0
    mkdir -p "$archive" 2>/dev/null || true
    local ttl="${1:-${RALPH_SKILL_TTL_DAYS:-30}}"
    local now_epoch f status updated upd_epoch age
    now_epoch=$(declare -F _signal_epoch >/dev/null && _signal_epoch "$(_skill_now)" || echo 0)
    for f in "$dir"/*.json; do
        [[ -f "$f" ]] || continue
        status=$(jq -r '.status // ""' "$f" 2>/dev/null) || continue
        [[ "$status" == "approved" ]] && continue   # keep approved skills forever
        updated=$(jq -r '.updated_at // ""' "$f" 2>/dev/null)
        upd_epoch=$(declare -F _signal_epoch >/dev/null && _signal_epoch "$updated" || echo 0)
        age=$(( (now_epoch - upd_epoch) / 86400 ))
        if [[ "$status" == "rejected" || $age -ge $ttl ]]; then
            mv -f "$f" "$archive/" 2>/dev/null || true
        fi
    done
}

#######################################
# Promote an APPROVED project skill into the HOME-global store so the proven fix can
# be recalled in ANY repo (mirrors the cross-project genetic-memory pattern). Only
# approved skills qualify — globalizing is the cross-project trust gate.
# Arguments: $1 theme_key
# Returns: echoes the theme on success; non-zero if the skill is missing/unapproved.
#######################################
globalize_skill() {
    command_exists jq || return 1
    local theme="$1"
    [[ -n "$theme" ]] || return 1
    local src="${SKILL_DIR:-.ralph/artifacts/skills}/$theme.json"
    [[ -f "$src" ]] || return 1
    local status; status=$(jq -r '.status // ""' "$src" 2>/dev/null) || status=""
    [[ "$status" == "approved" ]] || return 1

    local gdir="${RALPH_GLOBAL_SKILL_DIR:-${HOME:-}/.config/ralph/skills}"
    mkdir -p "$gdir" 2>/dev/null || true
    local now origin tmp
    now=$(_skill_now)
    origin=$(basename "${PROJECT_DIR:-$PWD}" 2>/dev/null) || origin=unknown  # _RALPH_DIR basename is always ".ralph"
    [[ -n "$origin" ]] || origin=unknown
    tmp=$(mktemp "$gdir/.skill.XXXXXX" 2>/dev/null) || tmp=$(mktemp) || return 1
    if jq --arg now "$now" --arg origin "$origin" \
          '.scope = "global" | .globalized_at = $now | .origin_project = (.origin_project // $origin)' \
          "$src" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$gdir/$theme.json" || { rm -f "$tmp"; return 1; }
    else
        rm -f "$tmp"; return 1
    fi
    printf '%s\n' "$theme"
}

#######################################
# Human-readable global (cross-project) skill table (CLI).
#######################################
list_global_skills() {
    command_exists jq || { echo "jq required"; return 0; }
    local gdir="${RALPH_GLOBAL_SKILL_DIR:-${HOME:-}/.config/ralph/skills}"
    [[ -d "$gdir" ]] || { echo "No global skills."; return 0; }
    local f any=0
    for f in "$gdir"/*.json; do
        [[ -f "$f" ]] || continue
        jq -r '"[global] \(.theme_key) — \(.resolution)  (from \(.origin_project // "?"))"' "$f" 2>/dev/null || continue
        any=1
    done
    [[ $any -eq 0 ]] && echo "No global skills."
    return 0
}

#######################################
# CLI dispatch: ralph skill [ls|show|approve|reject|globalize|global|recall]
#######################################
handle_skill_command() {
    local cmd="${1:-ls}"; shift 2>/dev/null || true
    case "$cmd" in
        ls|list)  list_skills "${1:-}" ;;
        show|get) skill_get "${1:-}" ;;
        approve)  if [[ -n "${1:-}" ]]; then approve_skill "$1" && echo "Approved skill: $1"; else echo "Usage: ralph skill approve <theme>"; fi ;;
        reject)   if [[ -n "${1:-}" ]]; then reject_skill "$1" && echo "Rejected skill: $1"; else echo "Usage: ralph skill reject <theme>"; fi ;;
        globalize)
            if [[ -z "${1:-}" ]]; then
                echo "Usage: ralph skill globalize <theme>"
            elif globalize_skill "$1" >/dev/null; then
                echo "Globalized skill: $1 (now recalled in every repo)"
            else
                echo "Cannot globalize '$1' (must be an existing approved skill)"
            fi
            ;;
        global)   list_global_skills ;;
        recall)   recall_skills ;;
        *)        echo "Usage: ralph skill [ls|show <theme>|approve <theme>|reject <theme>|globalize <theme>|global|recall]" ;;
    esac
}
