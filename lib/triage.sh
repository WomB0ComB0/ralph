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
            [[ -f "$f" ]] && cat "$f"
        fi
    } | awk '{ sub(/#.*/,""); gsub(/[ \t\r]/,"") } /^[^\/]+\/[^\/]+$/ && !seen[$0]++ { print }'
}

# Parse `gh run list --json name,headBranch,url` -> TSV findings (sev\trepo\tcategory\tsummary\turl).
_triage_parse_runs() {
    local repo="$1"
    jq -r --arg r "$repo" '
        arrays[] |"medium\t\($r)\tci\t\((.name // "workflow")) failed on \((.headBranch // "?"))\t\((.url // ""))"
    ' 2>/dev/null || true
}

# Parse a `gh api .../alerts` array (kind: dependabot | code-scanning | secret-scanning).
_triage_parse_alerts() {
    local repo="$1" kind="$2"
    case "$kind" in
        dependabot)
            jq -r --arg r "$repo" 'arrays[] | select((.state // "open")=="open")
                | "\((.security_advisory.severity // "low"))\t\($r)\tdependabot\t\((.dependency.package.name // "?")): \((.security_advisory.summary // "vulnerable dependency"))\t\((.html_url // ""))"' 2>/dev/null || true ;;
        code-scanning)
            jq -r --arg r "$repo" 'arrays[] | select((.state // "open")=="open")
                | "\((.rule.security_severity_level // .rule.severity // "warning"))\t\($r)\tcode-scan\t\((.rule.description // .rule.id // "code scanning alert"))\t\((.html_url // ""))"' 2>/dev/null || true ;;
        secret-scanning)
            jq -r --arg r "$repo" 'arrays[] | select((.state // "open")=="open")
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

# Deterministic, clearly bot-namespaced fix branch (so a human PR can never collide / be mistaken).
triage_ci_branch_name() { printf 'ralph/fix-ci-%s\n' "$1"; }

# Safety gate for ANY push: only a non-empty `ralph/fix-*` branch that isn't the default branch
# may be pushed. This is the last line of defense against ever writing to a default branch.
_triage_safe_push_branch() {
    local branch="$1" default="$2"
    [[ -n "$branch" && "$branch" != "$default" && "$branch" == ralph/fix-* ]]
}

# Attempt to fix the latest failing CI run for ONE repo and open a PR. DRY-RUN by default
# (prints the exact plan, writes nothing); pass apply=1 to execute. Even with apply, it works
# in a throwaway clone, only ever pushes the ralph/fix-* branch, opens the PR against the
# default branch, and never touches the default branch itself.
triage_autofix_ci() {
    local repo="$1" apply="${2:-0}" run_override="${3:-}"
    # iteration is referenced by run_ai_tool (status bar/logging); set it so the call doesn't
    # trip `set -u` when invoked outside the normal iteration loop.
    local run_json run_id run_url default_branch base_branch branch iteration=1
    if [[ -n "$run_override" ]]; then
        # Operator picked a specific run (e.g. a known code-fixable one). Look it up directly.
        run_id="$run_override"
        run_json=$(gh run view "$run_id" --repo "$repo" --json url,headBranch 2>/dev/null || echo '{}')
        run_url=$(printf '%s' "$run_json" | jq -r '.url // ""' 2>/dev/null || true)
        base_branch=$(printf '%s' "$run_json" | jq -r '.headBranch // empty' 2>/dev/null || true)
        if [[ -z "$run_url" ]]; then
            log_error "[$repo] run $run_id not found or could not be retrieved."
            return 1
        fi
    else
        run_json=$(gh run list --repo "$repo" --status failure --limit 1 --json databaseId,url,headBranch 2>/dev/null || echo '[]')
        run_id=$(printf '%s' "$run_json" | jq -r 'arrays[0].databaseId // empty' 2>/dev/null || true)
        run_url=$(printf '%s' "$run_json" | jq -r 'arrays[0].url // ""' 2>/dev/null || true)
        base_branch=$(printf '%s' "$run_json" | jq -r 'arrays[0].headBranch // empty' 2>/dev/null || true)
    fi
    if [[ -z "$run_id" ]]; then
        log_info "[$repo] no failing CI run — nothing to fix."
        return 0
    fi
    default_branch=$(gh repo view "$repo" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo main)
    # Fix on the branch that's ACTUALLY failing (e.g. a renovate/dependabot PR branch), not
    # always the default — the broken code lives there. PR targets that same branch so merging
    # the fix turns the failing run green. Falls back to the default branch.
    [[ -z "$base_branch" ]] && base_branch="$default_branch"
    branch=$(triage_ci_branch_name "$run_id")

    if [[ "$apply" != "1" ]]; then
        log_info "[$repo] DRY-RUN — would attempt to fix CI run $run_url"
        printf '    clone   %s -> throwaway worktree\n' "$repo"
        printf '    branch  %s (off the failing branch %s)\n' "$branch" "$base_branch"
        printf '    model   %s\n' "${RALPH_LOCAL_MODEL:-<resolved at run; local-first if configured>}"
        printf '    on diff git push origin %s ; gh pr create --base %s --head %s\n' "$branch" "$base_branch" "$branch"
        printf '    will NEVER push to %s. Re-run with --apply to execute.\n' "$default_branch"
        return 0
    fi

    command_exists git || { log_error "git is required for --apply."; return 1; }
    local work; work=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$work'" RETURN
    log_info "[$repo] cloning $base_branch to fix CI run $run_id ..."
    # Clone the FAILING branch directly (--depth 50 is single-branch, so a later fetch+checkout of a
    # different branch silently fails and leaves us on the default branch — where the bug isn't).
    if ! gh repo clone "$repo" "$work" -- --depth 50 --branch "$base_branch" >/dev/null 2>&1; then
        log_error "[$repo] clone of branch '$base_branch' failed."; return 1
    fi
    local logs prompt lf of full
    # Focus the prompt on the ACTUAL error lines (compiler/test/lint), not the raw stack-trace
    # tail — the error lines are what the agent needs to locate the fix. Fall back to the tail.
    full=$(gh run view "$run_id" --repo "$repo" --log-failed 2>/dev/null || true)
    logs=$(printf '%s\n' "$full" | grep -iE 'error|failed|cannot|expected|undefined|not found|TS[0-9]{3,}' | grep -vE '^[[:space:]]*$' | tail -n 60)
    [[ -z "$logs" ]] && logs=$(printf '%s\n' "$full" | tail -n 80)
    if [[ -z "$logs" ]]; then
        log_error "[$repo] no failing-log output for run $run_id (expired/permissions?) — can't fix blind."
        return 1
    fi
    prompt=$(printf 'The GitHub Actions CI run %s failed for %s.\n\nKey error lines:\n%s\n\nReproduce and fix this with a MINIMAL source-code change (e.g. a type annotation, an import, or a renamed API) to the source files named in the errors. You MAY install dependencies and run the failing check (typecheck/test/lint) to verify your fix actually passes. Do NOT deliberately change dependency versions or CI/workflow files — fix it in the source. (Incidental lockfile updates from installing are fine; they are discarded automatically.)' "$run_url" "$repo" "$logs")
    # Agent log/out live OUTSIDE the clone so `git add -A` can never commit them into the PR.
    lf=$(mktemp); of=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -rf '$work' '$lf' '$of'" RETURN
    # Check out the FAILING branch (it may not be the default), then branch the fix off it so the
    # agent sees the broken code. PROJECT_DIR must point at the CLONE so tools that bind a working
    # dir (e.g. agy --add-dir) operate on the throwaway checkout, not the original repo.
    # Default to the tool's OWN model self-selection unless a local model / pin is explicitly
    # configured: the auto-resolved "newest" model isn't guaranteed to be authenticated, whereas
    # the tool's built-in default is. RALPH_LOCAL_MODEL still wins (local-first preserved).
    local fix_model_source="fallback"
    [[ -z "${RALPH_LOCAL_MODEL:-}" && -z "${SELECTED_MODEL:-}" ]] && fix_model_source="selfselect"
    ( cd "$work" && export PROJECT_DIR="$work"
      git checkout -b "$branch" >/dev/null 2>&1   # already on $base_branch from the clone
      if [[ "$fix_model_source" == "selfselect" ]]; then
          # run_ai_with_fallback ALWAYS resolves a concrete model (resolve_model_for_tool), which
          # may not be authenticated. When the user pinned nothing, bypass it and pass an empty
          # model so the tool self-selects its own working default.
          RALPH_ROLE=engineer retry_with_backoff "${AI_RETRY_ATTEMPTS:-2}" "${AI_RETRY_BASE_DELAY:-5}" -- run_ai_tool "${TOOL:-opencode}" "" "$prompt" "$lf" "$of"
      else
          RALPH_ROLE=engineer run_ai_with_fallback "${TOOL:-opencode}" engineer "$prompt" "$lf" "$of"
      fi ) || true

    # Discard any dependency/lockfile/workflow churn the agent may have introduced — a fix for a
    # dep-bump CI break should be SOURCE-ONLY (lockfiles are renovate/CI's domain). Done before the
    # change-check so a PR is opened only if there's a real source fix.
    ( cd "$work" \
        && git checkout -- package.json package-lock.json yarn.lock pnpm-lock.yaml bun.lock 2>/dev/null; \
        git clean -f -- package-lock.json yarn.lock pnpm-lock.yaml bun.lock 2>/dev/null; \
        git checkout -- .github 2>/dev/null; git clean -fd -- .github 2>/dev/null ) || true

    if [[ -z "$(cd "$work" && git status --porcelain 2>/dev/null)" ]]; then
        log_warning "[$repo] fix attempt produced no changes — no PR opened."
        return 0
    fi
    local cur; cur=$(cd "$work" && git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    if ! _triage_safe_push_branch "$cur" "$default_branch"; then
        log_error "[$repo] refusing to push: on '$cur' (not a ralph/fix-* branch off '$default_branch')."
        return 1
    fi
    # Local identity in the clone so the commit succeeds even with no global git user config.
    if ! ( cd "$work" \
            && git config user.name "ralph-bot" \
            && git config user.email "ralph-bot@users.noreply.github.com" \
            && git add -A \
            && git commit -q -m "fix: resolve failing CI (run $run_id)

Automated fix by \`ralph triage --fix-ci\` (local model). Please review before merging." \
            && git push -u origin "$cur" >/dev/null 2>&1 ); then
        log_error "[$repo] commit/push failed."; return 1
    fi
    gh pr create --repo "$repo" --base "$base_branch" --head "$cur" \
        --title "fix: resolve failing CI (run $run_id)" \
        --body "Automated CI fix from \`ralph triage --fix-ci\` using a local model. Failing run: $run_url

⚠️ Agent-generated — please review before merging." 2>&1 | tail -1
    log_success "[$repo] opened a PR from $cur against $base_branch."
    return 0
}

# Orchestrate the read-only triage across the allowlist; record each finding as a signal.
handle_triage_command() {
    # Flags: --fix-ci switches from the read-only report to the CI-autofix path; --apply turns
    # the (default) dry-run into a real clone+fix+PR. Read-only report is the default — no flags.
    local mode="report" apply=0 run_override=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --fix-ci) mode="fix-ci" ;;
            --apply)  apply=1 ;;
            --run)    run_override="${2:-}"; shift ;;
        esac
        shift
    done
    if ! command_exists gh || ! command_exists jq; then
        log_error "triage needs the GitHub CLI (gh, authenticated) and jq installed."
        return 1
    fi
    local -a targets=(); mapfile -t targets < <(triage_load_targets)
    if [[ ${#targets[@]} -eq 0 ]]; then
        log_error "No triage targets. Set RALPH_TARGETS=\"owner/repo,owner/repo\" or create a ralph.targets file (one owner/repo per line)."
        return 1
    fi
    if [[ "$mode" == "fix-ci" ]]; then
        [[ "$apply" == "1" ]] || log_warning "DRY-RUN (no --apply): showing the plan only — nothing is cloned, pushed, or opened."
        local r
        for r in "${targets[@]}"; do triage_autofix_ci "$r" "$apply" "$run_override" || true; done
        return 0
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
        record_signal "triage_${cat}_${repo2//[^a-zA-Z0-9]/_}" "$cat finding in $repo2" "$summary${url:+ ($url)}" "review and resolve: $summary" "triage" "$sev" >/dev/null 2>&1 || true
    done < "$all"
    rm -f "$all"
    log_info "Recorded findings as signals (see 'ralph signal ls'). Autofix→PR / suggest modes are opt-in (coming next)."
    return 0
}
