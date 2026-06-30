#!/bin/bash
# lib/triage.sh — cross-repo, READ-ONLY GitHub triage.
#
# The "one central local agent with gh access" model gh-aw doesn't fill: point Ralph at an
# explicit allowlist of repos and surface actionable work (failing CI + open security alerts)
# via `gh`, recording each as a Ralph signal so it compounds across runs. This module writes
# NOTHING to any repo — the autofix→PR and suggest→issue modes are separate and opt-in.

# Severity ordering for the report (higher = more urgent). Maps GitHub's two scales
# (critical/high/medium/low and error/warning/note) onto one rank.
_triage_sev_rank() {
    case "${1,,}" in
        critical) echo 5 ;;
        high|error) echo 4 ;;
        medium|warning) echo 3 ;;
        low|note) echo 2 ;;
        *) echo 1 ;;
    esac
}

# Load the explicit repo allowlist (owner/repo per line). RALPH_TARGETS (comma/space/newline
# separated) wins; else RALPH_TARGETS_FILE or ./ralph.targets. `#` comments + blanks stripped,
# only owner/repo kept, deduped (order preserved). The allowlist is the safety boundary —
# triage can never touch a repo that isn't listed here.
triage_load_targets() {
    local dir="${1:-${PROJECT_DIR:-.}}"
    {
        if [[ -n "${RALPH_TARGETS:-}" ]]; then
            printf '%s\n' "$RALPH_TARGETS" | tr ',' '\n' | tr ' ' '\n'
        else
            local f="${RALPH_TARGETS_FILE:-$dir/ralph.targets}"
            [[ -f "$f" ]] && sed 's/#.*//' "$f"
        fi
    } | awk '{ gsub(/[ \t\r]/,"") } /^[^\/]+\/[^\/]+$/ && !seen[$0]++ { print }'
}

# Parse `gh run list --json name,headBranch,url` -> TSV findings (sev\trepo\tcategory\tsummary\turl).
_triage_parse_runs() {
    local repo="$1"
    jq -r --arg r "$repo" '
        .[]? | "medium\t\($r)\tci\t\((.name // "workflow")) failed on \((.headBranch // "?"))\t\((.url // ""))"
    ' 2>/dev/null || true
}

# Parse a `gh api .../alerts` array (kind: dependabot | code-scanning | secret-scanning).
_triage_parse_alerts() {
    local repo="$1" kind="$2"
    case "$kind" in
        dependabot)
            jq -r --arg r "$repo" '.[]? | select((.state // "open")=="open")
                | "\((.security_advisory.severity // "low"))\t\($r)\tdependabot\t\((.dependency.package.name // "?")): \((.security_advisory.summary // "vulnerable dependency"))\t\((.html_url // ""))"' 2>/dev/null || true ;;
        code-scanning)
            jq -r --arg r "$repo" '.[]? | select((.state // "open")=="open")
                | "\((.rule.security_severity_level // .rule.severity // "warning"))\t\($r)\tcode-scan\t\((.rule.description // .rule.id // "code scanning alert"))\t\((.html_url // ""))"' 2>/dev/null || true ;;
        secret-scanning)
            jq -r --arg r "$repo" '.[]? | select((.state // "open")=="open")
                | "high\t\($r)\tsecret\t\((.secret_type_display_name // .secret_type // "leaked secret"))\t\((.html_url // ""))"' 2>/dev/null || true ;;
    esac
}

# Read-only scan of ONE repo: failing CI + the three security-alert feeds. Each gh call is
# guarded — a missing scope, disabled feature, or unknown repo just yields no findings.
triage_scan_repo() {
    local repo="$1" ci_limit="${RALPH_TRIAGE_CI_LIMIT:-5}"
    gh run list --repo "$repo" --status failure --limit "$ci_limit" --json name,headBranch,url 2>/dev/null \
        | _triage_parse_runs "$repo"
    gh api "repos/$repo/dependabot/alerts?state=open&per_page=30"      2>/dev/null | _triage_parse_alerts "$repo" dependabot
    gh api "repos/$repo/code-scanning/alerts?state=open&per_page=30"   2>/dev/null | _triage_parse_alerts "$repo" code-scanning
    gh api "repos/$repo/secret-scanning/alerts?state=open&per_page=30" 2>/dev/null | _triage_parse_alerts "$repo" secret-scanning
    return 0
}

# Print a severity-sorted, grouped report from a TSV findings file.
_triage_report() {
    local f="$1" rank sev repo cat summary url
    while IFS=$'\t' read -r sev repo cat summary url; do
        [[ -z "$repo" ]] && continue
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(_triage_sev_rank "$sev")" "$sev" "$repo" "$cat" "$summary" "$url"
    done < "$f" | sort -t$'\t' -k1,1rn -k3,3 | while IFS=$'\t' read -r rank sev repo cat summary url; do
        printf '  [%-8s] %-26s %-12s %s\n' "$sev" "$repo" "$cat" "$summary"
        [[ -n "$url" ]] && printf '             %s\n' "$url"
    done
}

# Orchestrate the read-only triage across the allowlist; record each finding as a signal.
handle_triage_command() {
    if ! command_exists gh; then
        log_error "triage needs the GitHub CLI (gh) with an authenticated token."
        return 1
    fi
    local -a targets=(); mapfile -t targets < <(triage_load_targets)
    if [[ ${#targets[@]} -eq 0 ]]; then
        log_error "No triage targets. Set RALPH_TARGETS=\"owner/repo,owner/repo\" or create a ralph.targets file (one owner/repo per line)."
        return 1
    fi
    log_info "Triaging ${#targets[@]} repo(s), read-only: ${targets[*]}"
    local all repo; all=$(mktemp)
    for repo in "${targets[@]}"; do
        triage_scan_repo "$repo" >> "$all" || true
    done
    # NB: `grep -c` PRINTS 0 and EXITS 1 on no matches, so `|| echo 0` would yield "0\n0" and
    # break the arithmetic below — count lines with wc instead.
    local count; count=$(wc -l < "$all" 2>/dev/null | tr -d ' '); count=${count:-0}
    if [[ "$count" -eq 0 ]]; then
        log_success "Triage clean: no failing CI or open security alerts across ${#targets[@]} repo(s)."
        rm -f "$all"; return 0
    fi
    echo
    log_warning "Found $count item(s) needing attention:"
    _triage_report "$all"
    echo
    # Compound: record each finding as a deduped signal (frequency climbs if it recurs).
    local sev repo2 cat summary url
    while IFS=$'\t' read -r sev repo2 cat summary url; do
        [[ -z "$repo2" ]] && continue
        record_signal "triage_${cat}_${repo2//[^a-zA-Z0-9]/_}" "$cat finding in $repo2" "$summary ${url:+($url)}" "review and resolve: $summary" "triage" "$sev" >/dev/null 2>&1 || true
    done < "$all"
    rm -f "$all"
    log_info "Recorded findings as signals (see 'ralph signal ls'). Autofix→PR / suggest modes are opt-in (coming next)."
    return 0
}
