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

# Parse the GraphQL reviewThreads payload -> TSV of UNRESOLVED threads: id\tauthor\tpath\tline\tbody.
_triage_parse_threads() {
    jq -r '.data.repository.pullRequest.reviewThreads.nodes[]? | select(.isResolved==false and (.comments.nodes[0] != null))
        | [ .id,
            (.comments.nodes[0].author.login // "?"),
            (.comments.nodes[0].path // "-"),
            ((.comments.nodes[0].line // 0)|tostring),
            ((.comments.nodes[0].body // "")|gsub("[\n\t\r]";" ")) ] | @tsv' 2>/dev/null || true
}

# Close out review CONVERSATIONS on one of Ralph's own fix PRs: address each unresolved thread
# with the agent, push to the PR branch, then reply + mark the conversation resolved. DRY-RUN by
# default. Hard-scoped to ralph/fix-* PRs so it can never auto-dismiss a human's PR review.
triage_resolve_reviews() {
    local repo="$1" pr="$2" apply="${3:-0}" iteration=1
    local owner name; owner="${repo%%/*}"; name="${repo##*/}"
    local q='query($o:String!,$n:String!,$pr:Int!){repository(owner:$o,name:$n){pullRequest(number:$pr){headRefName reviewThreads(first:50){nodes{id isResolved comments(first:1){nodes{author{login} path line body}}}}}}}'
    local data; data=$(gh api graphql -f query="$q" -F o="$owner" -F n="$name" -F pr="$pr" 2>/dev/null || echo '{}')
    local head; head=$(printf '%s' "$data" | jq -r '.data.repository.pullRequest.headRefName // ""' 2>/dev/null || true)
    if [[ -z "$head" ]]; then log_error "[$repo#$pr] PR not found / not retrievable."; return 1; fi
    # SAFETY: only ever act on Ralph's own fix branches — never resolve a human's conversation.
    if [[ "$head" != ralph/fix-* ]]; then
        log_error "[$repo#$pr] head '$head' is not a ralph/fix-* branch — refusing to resolve conversations."
        return 1
    fi
    local threads n; threads=$(printf '%s' "$data" | _triage_parse_threads)
    n=$(printf '%s' "$threads" | grep -c . 2>/dev/null || echo 0)
    if [[ "$n" -eq 0 ]]; then log_success "[$repo#$pr] no unresolved review conversations."; return 0; fi

    if [[ "$apply" != "1" ]]; then
        log_warning "[$repo#$pr] $n unresolved conversation(s) — DRY-RUN (would address + resolve):"
        printf '%s\n' "$threads" | while IFS=$'\t' read -r id author path line body; do
            [[ -z "$id" ]] && continue
            printf '  @%-18s %s:%s  %s\n' "$author" "$path" "$line" "${body:0:90}"
        done
        printf '    re-run with --apply to address each, push to %s, and resolve the conversations.\n' "$head"
        return 0
    fi

    command_exists git || { log_error "git required for --apply."; return 1; }
    local work lf of; work=$(mktemp -d); lf=$(mktemp); of=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -rf '$work' '$lf' '$of'" RETURN
    log_info "[$repo#$pr] cloning $head to address $n conversation(s) ..."
    if ! gh repo clone "$repo" "$work" -- --depth 50 --branch "$head" >/dev/null 2>&1; then
        log_error "[$repo#$pr] clone of '$head' failed."; return 1
    fi
    local prompt comments
    comments=$(printf '%s\n' "$threads" | while IFS=$'\t' read -r id author path line body; do [[ -z "$id" ]] || printf -- '- %s:%s — %s\n' "$path" "$line" "$body"; done)
    prompt=$(printf 'Address these unresolved pull-request review comments with MINIMAL source-code changes (one fix per comment):\n%s\n\nEdit only the source files referenced. Do NOT change dependency versions, lockfiles, or CI/workflow files.' "$comments")
    ( cd "$work" && export PROJECT_DIR="$work"
      if [[ -z "${RALPH_LOCAL_MODEL:-}" && -z "${SELECTED_MODEL:-}" && "${TOOL:-opencode}" == "opencode" ]]; then
          RALPH_ROLE=engineer retry_with_backoff "${AI_RETRY_ATTEMPTS:-2}" "${AI_RETRY_BASE_DELAY:-5}" -- run_ai_tool opencode "" "$prompt" "$lf" "$of"
      else
          RALPH_ROLE=engineer run_ai_with_fallback "${TOOL:-opencode}" engineer "$prompt" "$lf" "$of"
      fi ) || true
    ( cd "$work" \
        && git checkout -- package.json package-lock.json yarn.lock pnpm-lock.yaml bun.lock 2>/dev/null; \
        git clean -f -- package-lock.json yarn.lock pnpm-lock.yaml bun.lock 2>/dev/null; \
        git checkout -- .github 2>/dev/null; git clean -fd -- .github 2>/dev/null ) || true
    if [[ -z "$(cd "$work" && git status --porcelain 2>/dev/null)" ]]; then
        log_warning "[$repo#$pr] agent produced no changes — conversations left OPEN (not resolved)."
        return 0
    fi
    if ! _triage_safe_push_branch "$head" "${head}__never"; then   # head is ralph/fix-* by the gate above
        log_error "[$repo#$pr] refusing to push '$head'."; return 1
    fi
    if ! ( cd "$work" \
            && git config user.name "ralph-bot" && git config user.email "ralph-bot@users.noreply.github.com" \
            && git add -A && git commit -q -m "fix: address review comments on #$pr (automated)" \
            && git push origin HEAD >/dev/null 2>&1 ); then
        log_error "[$repo#$pr] commit/push failed."; return 1
    fi
    local sha; sha=$(cd "$work" && git rev-parse --short HEAD 2>/dev/null || echo "")
    # Only NOW resolve each conversation — and only because we pushed a real change addressing them.
    printf '%s\n' "$threads" | while IFS=$'\t' read -r id author path line body; do
        [[ -z "$id" ]] && continue
        gh api graphql -f query='mutation($id:ID!,$b:String!){addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$id,body:$b}){comment{id}}}' -f id="$id" -f b="Addressed in $sha (automated by \`ralph triage --resolve-reviews\`)." >/dev/null 2>&1 || true
        gh api graphql -f query='mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{isResolved}}}' -f id="$id" >/dev/null 2>&1 || true
    done
    log_success "[$repo#$pr] addressed + resolved $n conversation(s) (pushed $sha to $head)."
    return 0
}

# Orchestrate the read-only triage across the allowlist; record each finding as a signal.
handle_triage_command() {
    # Flags: --fix-ci switches from the read-only report to the CI-autofix path; --apply turns
    # the (default) dry-run into a real clone+fix+PR. Read-only report is the default — no flags.
    local mode="report" apply=0 run_override="" resolve_pr=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --fix-ci)          mode="fix-ci" ;;
            --apply)           apply=1 ;;
            --run)             run_override="${2:-}"; shift ;;
            --resolve-reviews) mode="resolve-reviews"; resolve_pr="${2:-}"; shift ;;
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
    if [[ "$mode" == "resolve-reviews" ]]; then
        if [[ ! "$resolve_pr" =~ ^[0-9]+$ ]]; then log_error "--resolve-reviews needs a numeric PR number, e.g. 'ralph triage --resolve-reviews 475'."; return 1; fi
        [[ "$apply" == "1" ]] || log_warning "DRY-RUN (no --apply): listing unresolved conversations only — nothing is pushed or resolved."
        local r
        for r in "${targets[@]}"; do triage_resolve_reviews "$r" "$resolve_pr" "$apply" || true; done
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
