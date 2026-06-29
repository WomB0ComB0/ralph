#!/bin/bash
# shellcheck disable=SC2154
#######################################
# Knowledge-hygiene "lint" pass over the signals + skills compounding layers.
#
# This is the periodic CURATOR sweep — the layer the per-iteration operator never
# gets to because it is busy doing tasks. It is READ-ONLY (no mutations) and
# surfaces decayed / missing / unreviewed knowledge so a human can groom it:
#   - KNOWLEDGE GAPS:   recurring open problem with no captured skill yet
#   - ORPHANED SKILLS:  a skill whose signal no longer exists (pruned/archived)
#   - STALE SKILLS:     an approved skill whose signal has been idle past a TTL
#   - APPROVAL BACKLOG: candidate skills awaiting human approve/reject
#   - HIGH-SEVERITY:    open high-severity signals still unresolved
# No-op without jq. Reuses _signal_now / _signal_epoch from lib/signals.sh.
#######################################

# Whole days between now and an ISO timestamp; 99999 if unparseable/missing.
_lint_age_days() {
    local iso="$1" now_e last_e
    now_e=$(_signal_epoch "$(_signal_now)" 2>/dev/null || echo 0)
    last_e=$(_signal_epoch "$iso" 2>/dev/null || echo 0)
    # Unknown 'now' (broken clock) -> treat as fresh (age 0), don't falsely flag stale.
    [[ "$now_e" =~ ^[0-9]+$ && "$now_e" -gt 0 ]] || { echo 0; return; }
    # Unknown/missing last_seen -> very old, so it surfaces for review.
    [[ "$last_e" =~ ^[0-9]+$ && "$last_e" -gt 0 ]] || { echo 99999; return; }
    (( now_e > last_e )) || { echo 0; return; }
    echo $(( (now_e - last_e) / 86400 ))
}

# Print one report section: a title, its count, and each item (skipped in quiet).
_lint_section() {
    local title="$1"; shift
    printf '\n== %s: %d ==\n' "$title" "$#"
    local item
    for item in "$@"; do printf '  - %s\n' "$item"; done
}

#######################################
# Audit the knowledge store and print a grouped, actionable report.
# Arguments: [$1] "quiet" prints only the one-line summary (for review_run).
# Honors RALPH_LINT_MIN_FREQ (default = RALPH_SKILL_MIN_FREQ or 2) and
# RALPH_LINT_STALE_DAYS (default 30). Returns 0 (informational).
#######################################
lint_knowledge() {
    command_exists jq || { echo "lint summary: jq required"; return 0; }
    local quiet=""; [[ "${1:-}" == "quiet" ]] && quiet=1

    local sdir="${SIGNAL_DIR:-.ralph/artifacts/signals}"
    local kdir="${SKILL_DIR:-.ralph/artifacts/skills}"
    local min_freq="${RALPH_LINT_MIN_FREQ:-${RALPH_SKILL_MIN_FREQ:-2}}"
    local stale_days="${RALPH_LINT_STALE_DAYS:-30}"
    [[ "$min_freq" =~ ^[0-9]+$ ]] || min_freq=2
    [[ "$stale_days" =~ ^[0-9]+$ ]] || stale_days=30

    local gaps=() orphans=() stale=() backlog=() highsev=()
    local f theme status freq sev last skillfile sigfile sk_status age covered sst

    # --- Signal-driven checks ---
    if [[ -d "$sdir" ]]; then
        for f in "$sdir"/*.json; do
            [[ -f "$f" ]] || continue
            status=$(jq -r '.status // ""' "$f" 2>/dev/null) || continue
            theme=$(jq -r '.theme_key // ""' "$f" 2>/dev/null) || continue
            [[ -n "$theme" ]] || continue
            [[ "$status" == "open" || "$status" == "ack" ]] || continue
            freq=$(jq -r '.frequency // 0' "$f" 2>/dev/null) || freq=0; [[ "$freq" =~ ^[0-9]+$ ]] || freq=0
            sev=$(jq -r '.severity // "low"' "$f" 2>/dev/null) || sev=low; [[ -n "$sev" ]] || sev=low
            skillfile="$kdir/$theme.json"
            # A theme is "covered" only by a candidate/approved skill; a REJECTED skill
            # (or none at all) leaves the recurring problem an open gap.
            covered=1
            if [[ ! -f "$skillfile" ]]; then
                covered=0
            else
                sst=$(jq -r '.status // ""' "$skillfile" 2>/dev/null) || sst=""
                [[ "$sst" == "rejected" ]] && covered=0
            fi
            if [[ $freq -ge $min_freq && $covered -eq 0 ]]; then
                gaps+=("$theme (freq=$freq, sev=$sev)")
            fi
            [[ "$sev" == "high" ]] && highsev+=("$theme (freq=$freq)")
        done
    fi

    # --- Skill-driven checks ---
    if [[ -d "$kdir" ]]; then
        for f in "$kdir"/*.json; do
            [[ -f "$f" ]] || continue
            sk_status=$(jq -r '.status // ""' "$f" 2>/dev/null) || continue
            theme=$(jq -r '.theme_key // ""' "$f" 2>/dev/null) || continue
            [[ -n "$theme" ]] || continue
            sigfile="$sdir/$theme.json"
            case "$sk_status" in
                candidate)
                    # Disjoint: a candidate with a live signal is review backlog; one
                    # whose signal is gone is an orphan (not both).
                    if [[ -f "$sigfile" ]]; then
                        backlog+=("$theme")
                    else
                        orphans+=("$theme (candidate)")
                    fi
                    ;;
                approved)
                    if [[ ! -f "$sigfile" ]]; then
                        orphans+=("$theme (approved)")
                    else
                        last=$(jq -r '.last_seen // ""' "$sigfile" 2>/dev/null) || last=""
                        age=$(_lint_age_days "$last")
                        [[ "$age" =~ ^[0-9]+$ && $age -ge $stale_days ]] && stale+=("$theme (signal idle ${age}d)")
                    fi
                    ;;
            esac
        done
    fi

    if [[ -z "$quiet" ]]; then
        _lint_section "KNOWLEDGE GAPS (recurring open problem, no skill yet)" "${gaps[@]+"${gaps[@]}"}"
        _lint_section "ORPHANED SKILLS (skill references a signal that no longer exists)" "${orphans[@]+"${orphans[@]}"}"
        _lint_section "STALE APPROVED SKILLS (signal idle > ${stale_days}d; maybe obsolete)" "${stale[@]+"${stale[@]}"}"
        _lint_section "APPROVAL BACKLOG (candidate skills awaiting review)" "${backlog[@]+"${backlog[@]}"}"
        _lint_section "UNRESOLVED HIGH-SEVERITY SIGNALS" "${highsev[@]+"${highsev[@]}"}"
        printf '\n'
    fi
    printf 'lint summary: %d gaps, %d orphaned, %d stale, %d backlog, %d high-severity\n' \
        "${#gaps[@]}" "${#orphans[@]}" "${#stale[@]}" "${#backlog[@]}" "${#highsev[@]}"
    return 0
}

# CLI: ralph lint [quiet]
handle_lint_command() { lint_knowledge "${1:-}"; }
