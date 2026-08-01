# Ralph: Autonomous Up To The Merge — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make ralph's cross-repo CI autofix run unattended on an allowlist and hand the operator a trustworthy `ralph-ready` merge queue — stopping at the merge button.

**Architecture:** Three stacked PRs. A: make `_triage_apply_fix` idempotent via a `ralph-fix:<kind>:<key>` PR-body marker + a pre-clone dedup check. B: a new `triage_verify_fixes` pass that reads each ralph-fix PR's CI and labels `ralph-ready` (green) or flags it (red, + an `autofix_failed` signal). C: run `--verify-fixes` from the patrol after its apply pass, add verify counts to the soak summary, and document the autonomous config.

**Tech Stack:** Bash 3.2+, `gh` (via `_triage_gh_or_transient`), `jq`. Tests are shell harnesses under `tests/` that stub `gh` as a function.

## Global Constraints

- **Never merges.** No task adds any `gh pr merge`. The boundary is the merge button.
- **Autonomous path is CI-only.** The recommended unattended mode is `fix-ci-apply`; `fix-security-apply` stays for deliberate human-driven runs.
- **Allowlist-scoped**, `ralph/fix-*` branches only, never a default branch, source-only — all existing `_triage_apply_fix` rails are inherited and unchanged.
- **Only ralph's own PRs.** Verification acts only on PRs carrying a `ralph-fix:` body marker.
- **Idempotent.** Never duplicate a PR, label, comment, or signal. Every GitHub write is guarded by a marker/existence check.
- All `gh` calls go through `_triage_gh_or_transient "<label>" "$repo" gh ...` (rc 75 = transient → defer, preserve state).
- Bash: `[[ -n $x ]] || x=$(cmd) || {...}` (never `[[ -z ]] &&` for fallible assigns); `local -a x; x=()` separately; commit via `git commit -F <file>`.
- `_triage_apply_fix` signature today: `_triage_apply_fix repo base_branch branch prompt title body [apply=0] [filter_context]`.

---

### Task 1 (PR A): Idempotent autofix

**Files:**
- Modify: `lib/triage.sh` (`_triage_apply_fix`: add a `finding_key` arg + pre-clone dedup + marker append; callers `triage_autofix_ci` ~line 696, `triage_autofix_security` ~line 748 pass the key)
- Test: `tests/test_triage.sh`

**Interfaces:**
- Produces: `_triage_apply_fix repo base branch prompt title body [apply=0] [filter_context] [finding_key]` — new optional 9th arg `finding_key` (e.g. `ci:owner/repo` or `sec:7`). When set: (a) if an open PR already carries `<!-- ralph-fix:<finding_key> -->`, skip with zero work; (b) the created PR body ends with that marker.

- [ ] **Step 1: Write the failing tests** — append to `tests/test_triage.sh` before the final TOTAL:

```bash
echo "== idempotent autofix: dedup by ralph-fix marker + marker stamped on new PRs =="
unset -f gh
# (a) an existing open PR carrying the finding marker -> apply_fix skips (no clone, no pr create)
GHLOG="$TMP/gh-dedup"; : > "$GHLOG"
gh() {
    echo "gh $*" >> "$GHLOG"
    case "$*" in
        *"pr list"*"ralph-fix:ci:o/r"*) printf '[{"number":7,"body":"x <!-- ralph-fix:ci:o/r -->"}]\n' ;;
        *"repo view"*defaultBranchRef*) echo main ;;
        *) printf '\n' ;;
    esac
}
out=$(_triage_apply_fix "o/r" main "ralph/fix-ci-1" "prompt" "t" "body" 1 "" "ci:o/r" 2>&1)
printf '%s' "$out" | grep -qi 'already has an open fix PR #7' && ok "dedup skips when a marker-matching PR is open" || bad "no dedup skip: $out"
grep -qE 'clone|pr create' "$GHLOG" && bad "dedup still cloned/created a PR: $(cat "$GHLOG")" || ok "dedup did zero write-work"
# (b) dry-run with a key and NO existing PR -> plan is shown (proceeds)
gh() { case "$*" in *"pr list"*) printf '[]\n' ;; *defaultBranchRef*) echo main ;; *) printf '\n' ;; esac; }
d=$(_triage_apply_fix "o/r" main "ralph/fix-ci-1" "prompt" "t" "body" 0 "" "ci:o/r" 2>&1)
printf '%s' "$d" | grep -qi 'DRY-RUN' && ok "no existing PR -> autofix proceeds (dry-run plan shown)" || bad "did not proceed: $d"
unset -f gh
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test_triage.sh 2>&1 | grep -iE 'dedup|already has|zero write'`
Expected: FAIL — `_triage_apply_fix` ignores the 9th arg, so no dedup skip.

- [ ] **Step 3: Implement in `lib/triage.sh`.**

Change the signature line of `_triage_apply_fix`:
```bash
    local repo="$1" base_branch="$2" branch="$3" prompt="$4" title="$5" body="$6" apply="${7:-0}" filter_context="${8:-}" finding_key="${9:-}"
```

Immediately after `_triage_default_branch` resolves (right before the `if [[ "$apply" != "1" ]]` dry-run block), add the dedup check + marker:
```bash
    # Idempotency: one open ralph fix PR per finding. Skip (zero work) if one already exists.
    if [[ -n "$finding_key" ]]; then
        local _dup
        _dup=$(_triage_gh_or_transient "checking for an existing fix PR" "$repo" gh pr list --repo "$repo" --state open --search "ralph-fix:$finding_key in:body" --json number,body \
                 --jq "[.[] | select(.body | test(\"<!-- ralph-fix:$finding_key -->\"; \"x\")) | .number] | .[0] // empty") || _dup=""
        if [[ -n "$_dup" ]]; then
            log_success "[$repo] already has an open fix PR #$_dup for $finding_key — skipping."
            return 0
        fi
        # Stamp the marker so future ticks find this PR.
        body="$body

<!-- ralph-fix:$finding_key -->"
    fi
```
(Note: the marker append mutates the local `body`, which flows into both the dry-run plan and the `gh pr create --body "$body"`.)

Update the two callers to pass the key. `triage_autofix_ci` (the `_triage_apply_fix "$repo" "$base_branch" "$branch" ... "$apply"` call): append `"" "ci:$repo"`:
```bash
    _triage_apply_fix "$repo" "$base_branch" "$branch" "$prompt" \
        "fix: resolve failing CI (run $run_id)" \
        "Automated CI fix from \`ralph triage --fix-ci\` using a local model. Failing run: $run_url

⚠️ Agent-generated — please review before merging." "$apply" "" "ci:$repo"
```
`triage_autofix_security` (its `_triage_apply_fix` call already passes a filter_context as arg 8) — append `"sec:$number"` as arg 9 (the alert `number` local is in scope).

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test_triage.sh 2>&1 | grep -E 'TOTAL'`
Expected: PASS, 0 failed (existing tests + the 4 new dedup assertions).

- [ ] **Step 5: shellcheck + commit**

```bash
shellcheck -x lib/triage.sh || true
printf 'feat: idempotent autofix (one open ralph fix PR per finding)\n\n_triage_apply_fix gains a finding_key: it stamps a <!-- ralph-fix:key -->\nmarker on the PR body and, before any clone/agent work, skips when an open\nPR already carries that marker. ci -> ci:<repo> (one CI-fix PR per repo);\nsecurity -> sec:<alert>. Makes autofix safe to run on a timer.\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>\n' > /tmp/a-commit.txt
git add lib/triage.sh tests/test_triage.sh
git commit -F /tmp/a-commit.txt
```

Then open PR A: `gh pr create --base main --head <branch> --title "feat: idempotent autofix" --body-file <body>`.

---

### Task 2 (PR B): PR verification → `ralph-ready` merge queue

**Files:**
- Modify: `lib/triage.sh` (add `triage_verify_fixes`; add `--verify-fixes` flag + a `mode=verify-fixes` dispatch in `handle_triage_command` using `_triage_map_targets`)
- Test: `tests/test_triage.sh`

**Interfaces:**
- Consumes: the `<!-- ralph-fix:… -->` marker from Task 1; `_triage_map_targets` (existing); `record_signal` (signals.sh); `_triage_gh_or_transient`.
- Produces: `triage_verify_fixes repo [apply=0]` — dry-run default; prints `verify: N ready, M failing, K pending`; on `--apply` labels green PRs `ralph-ready` (+ a `<!-- ralph-verified -->` comment), and on red PRs removes the label, comments `<!-- ralph-fix-failed -->`, and records an `autofix_failed` signal. Never merges.

- [ ] **Step 1: Write the failing tests** — append to `tests/test_triage.sh`:

```bash
echo "== triage --verify-fixes: label green, flag red, never merge, idempotent =="
unset -f gh
export SIGNAL_DIR="$TMP/vf-sig"; rm -rf "$SIGNAL_DIR"; init_signals
GHLOG="$TMP/gh-verify"; : > "$GHLOG"
# one green PR (#10), one red PR (#11), both ralph-fix marked
gh() {
    echo "gh $*" >> "$GHLOG"
    case "$*" in
        *"pr list"*"ralph-fix"*) printf '10\n11\n' ;;
        *"pr view 10"*) printf '{"number":10,"statusCheckRollup":[{"conclusion":"SUCCESS"}],"mergeable":"MERGEABLE","comments":[],"labels":[]}\n' ;;
        *"pr view 11"*) printf '{"number":11,"statusCheckRollup":[{"conclusion":"FAILURE"}],"mergeable":"MERGEABLE","comments":[],"labels":[{"name":"ralph-ready"}]}\n' ;;
        *"label create"*) : ;;
        *"pr edit"*|*"pr comment"*) : ;;
        *) printf '\n' ;;
    esac
}
out=$(triage_verify_fixes "o/r" 1 2>&1)
printf '%s' "$out" | grep -qE 'verify: 1 ready, 1 failing' && ok "summary counts green vs red" || bad "bad summary: $out"
grep -qE 'pr edit 10 .*--add-label ralph-ready' "$GHLOG" && ok "green PR labelled ralph-ready" || bad "green not labelled: $(cat "$GHLOG")"
grep -qE 'pr edit 11 .*--remove-label ralph-ready' "$GHLOG" && ok "red PR ralph-ready removed" || bad "red label not removed: $(cat "$GHLOG")"
grep -qi 'pr merge' "$GHLOG" && bad "verify tried to MERGE" || ok "verify never merges"
find "$SIGNAL_DIR" -name '*.json' -not -path '*/.archive/*' | grep -q . && ok "red fix records an autofix_failed signal" || bad "no failure signal recorded"
# dry-run writes nothing
: > "$GHLOG"
triage_verify_fixes "o/r" 0 >/dev/null 2>&1
grep -qE 'pr edit|pr comment|label create' "$GHLOG" && bad "dry-run wrote to GitHub" || ok "dry-run performs no writes"
unset -f gh; unset SIGNAL_DIR
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test_triage.sh 2>&1 | grep -iE 'verify:|ralph-ready|never merge'`
Expected: FAIL — `triage_verify_fixes: command not found`.

- [ ] **Step 3: Implement `triage_verify_fixes` in `lib/triage.sh`** (place near `triage_suggest`):

```bash
# Verify ralph's OWN open fix PRs against their CI and build a ralph-ready merge queue.
# Green -> label ralph-ready (+ one-time comment). Red -> remove the label, comment once, and
# record an autofix_failed signal. NEVER merges. DRY-RUN by default.
triage_verify_fixes() {
    local repo="$1" apply="${2:-0}"
    local list rc=0
    list=$(_triage_gh_or_transient "listing ralph fix PRs" "$repo" gh pr list --repo "$repo" --state open --search "ralph-fix in:body" --json number --jq '.[].number') || rc=$?
    if [[ "$rc" -eq 75 ]]; then return 0; elif [[ "$rc" -ne 0 ]]; then log_error "[$repo] verify: failed to list fix PRs."; return 1; fi
    local ready=0 failing=0 pending=0 n view state merge has_ready has_verified has_failmark
    while IFS= read -r n; do
        [[ "$n" =~ ^[0-9]+$ ]] || continue
        view=$(_triage_gh_or_transient "reading PR #$n" "$repo" gh pr view "$n" --repo "$repo" --json number,statusCheckRollup,mergeable,comments,labels) || continue
        # state: FAILURE if any check failed; SUCCESS if all terminal-good; else PENDING.
        state=$(printf '%s' "$view" | jq -r '
            (.statusCheckRollup // []) as $c
            | if ($c | any((.conclusion // .state) as $s | $s == "FAILURE" or $s == "CANCELLED" or $s == "TIMED_OUT" or $s == "ERROR")) then "red"
              elif (($c | length) > 0) and ($c | all((.conclusion // .state) as $s | $s == "SUCCESS" or $s == "NEUTRAL" or $s == "SKIPPED" or $s == "COMPLETED")) then "green"
              else "pending" end' 2>/dev/null)
        merge=$(printf '%s' "$view" | jq -r '.mergeable // ""' 2>/dev/null)
        has_ready=$(printf '%s' "$view" | jq -r '[.labels[]?.name] | index("ralph-ready") // empty' 2>/dev/null)
        has_verified=$(printf '%s' "$view" | jq -r '[.comments[]?.body] | map(select(test("<!-- ralph-verified -->"))) | length' 2>/dev/null)
        has_failmark=$(printf '%s' "$view" | jq -r '[.comments[]?.body] | map(select(test("<!-- ralph-fix-failed -->"))) | length' 2>/dev/null)
        if [[ "$state" == "green" && "$merge" == "MERGEABLE" ]]; then
            ready=$((ready+1))
            if [[ "$apply" == "1" ]]; then
                _triage_gh_or_transient "creating ralph-ready label" "$repo" gh label create ralph-ready --repo "$repo" --color 0E8A16 --description "Ralph autofix: CI green, ready to merge" >/dev/null 2>&1 || true
                [[ -z "$has_ready" ]] && _triage_gh_or_transient "labelling PR #$n" "$repo" gh pr edit "$n" --repo "$repo" --add-label ralph-ready >/dev/null 2>&1 || true
                [[ "${has_verified:-0}" == "0" ]] && _triage_gh_or_transient "commenting on PR #$n" "$repo" gh pr comment "$n" --repo "$repo" --body "Ralph verified: CI is green and the PR is mergeable — ready for your review/merge.
<!-- ralph-verified -->" >/dev/null 2>&1 || true
            fi
        elif [[ "$state" == "red" ]]; then
            failing=$((failing+1))
            if [[ "$apply" == "1" ]]; then
                [[ -n "$has_ready" ]] && _triage_gh_or_transient "removing ralph-ready from PR #$n" "$repo" gh pr edit "$n" --repo "$repo" --remove-label ralph-ready >/dev/null 2>&1 || true
                [[ "${has_failmark:-0}" == "0" ]] && _triage_gh_or_transient "commenting on PR #$n" "$repo" gh pr comment "$n" --repo "$repo" --body "Ralph: CI is failing on this autofix — the fix did not hold. Left open for revision; not merging.
<!-- ralph-fix-failed -->" >/dev/null 2>&1 || true
                record_signal autofix_failed "Ralph autofix PR failed CI in $repo" "ralph fix PR #$n in $repo has failing CI" "revise or close the autofix PR" "triage,autofix" high "triage" >/dev/null 2>&1 || true
            fi
        else
            pending=$((pending+1))
        fi
    done <<< "$list"
    log_info "[$repo] verify: $ready ready, $failing failing, $pending pending$([[ "$apply" == "1" ]] || echo ' (dry-run)')"
    return 0
}
```

Add the flag + dispatch in `handle_triage_command`: in the arg `case`, add `--verify-fixes) mode="verify-fixes" ;;`. After the `tidy` dispatch block add:
```bash
    if [[ "$mode" == "verify-fixes" ]]; then
        [[ "$apply" == "1" ]] || log_warning "DRY-RUN (no --apply): reporting ralph fix PR status only — no labels/comments written."
        _triage_map_targets triage_verify_fixes "$apply"
        return 0
    fi
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test_triage.sh 2>&1 | grep -E 'TOTAL'`
Expected: PASS, 0 failed.

- [ ] **Step 5: shellcheck + commit + PR B**

```bash
shellcheck -x lib/triage.sh || true
printf 'feat: ralph triage --verify-fixes (ralph-ready merge queue)\n\ntriage_verify_fixes reads each ralph-fix PR CI: green + mergeable -> label\nralph-ready (+ one-time comment); red -> remove the label, comment once, and\nrecord an autofix_failed signal. Dry-run default, marker-guarded, NEVER\nmerges. Wired as a --verify-fixes mode over the target allowlist.\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>\n' > /tmp/b-commit.txt
git add lib/triage.sh tests/test_triage.sh
git commit -F /tmp/b-commit.txt
```

---

### Task 3 (PR C): Patrol enablement + soak summary + docs

**Files:**
- Modify: `scripts/org-patrol` (run `--verify-fixes --apply` after an apply-mode fix pass)
- Modify: `README.md` (an "Autonomous up to the merge" section)
- Test: `tests/test_org_scripts.sh`

**Interfaces:**
- Consumes: `ralph triage --verify-fixes` (Task 2). The patrol calls `"$ralph_bin" triage --verify-fixes --apply` scoped by the same `RALPH_TARGETS`/allowlist ralph triage uses.

- [ ] **Step 1: Write the failing test** — in `tests/test_org_scripts.sh`, extend the `$TMP/ralph.sh` stub so `triage --verify-fixes` is logged (the stub already logs `$*`), then add:

```bash
echo "== org-patrol runs verify-fixes after an apply fix pass =="
: > "$RALPH_CALL_LOG"
RALPH_BIN="$TMP/ralph.sh" "$R/scripts/org-patrol" --mode fix-ci-apply --org demo-org --targets-file "$TMP/patrol.targets" --code-write-targets 'demo-org/live' --no-synapse-check --no-resource-history >/dev/null 2>&1; rc=$?
grep -q 'triage --verify-fixes' "$RALPH_CALL_LOG" && ok "apply-mode patrol runs the verify-fixes pass" || bad "verify-fixes not run: $(cat "$RALPH_CALL_LOG")"
: > "$RALPH_CALL_LOG"
RALPH_BIN="$TMP/ralph.sh" "$R/scripts/org-patrol" --mode report --org demo-org --targets-file "$TMP/patrol.targets" --no-synapse-check --no-resource-history >/dev/null 2>&1
grep -q 'triage --verify-fixes' "$RALPH_CALL_LOG" && bad "report mode wrongly ran verify-fixes" || ok "report mode does not verify"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test_org_scripts.sh 2>&1 | grep -i verify`
Expected: FAIL — the patrol never calls `--verify-fixes`.

- [ ] **Step 3: Implement in `scripts/org-patrol`.** After the triage invocation (and before `write_soak_summary` runs via the trap), when the mode is a code-writing apply mode, run the verify pass:
```bash
case "$mode" in
    fix-ci-apply|fix-security-apply)
        printf 'verifying ralph fix PRs (ready-to-merge queue)...\n'
        "$ralph_bin" triage --verify-fixes --apply || printf 'WARNING: verify-fixes pass failed\n' >&2
        ;;
esac
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test_org_scripts.sh 2>&1 | grep -E 'verify|TOTAL'`
Expected: PASS.

- [ ] **Step 5: README + full suite + commit + PR C**

Add to `README.md` (Public Org Patrol section) an "Autonomous up to the merge" note: set `RALPH_ORG_TRIAGE_MODE=fix-ci-apply` + `RALPH_ORG_CODE_WRITE_TARGETS`; ralph opens idempotent CI-fix PRs and verifies them; merge the `ralph-ready` queue (`gh pr list --label ralph-ready`); ralph never merges and never touches security autonomously.

```bash
shellcheck -x scripts/org-patrol || true
bash tests/run_all.sh
printf 'feat: patrol enablement for autonomous-up-to-merge + docs\n\nAfter an apply-mode fix pass the patrol runs triage --verify-fixes --apply\nso each tick grows the ralph-ready merge queue. README documents the\nfix-ci-apply autonomous config and the merge-queue workflow. Report/suggest\nmodes do not verify.\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>\n' > /tmp/c-commit.txt
git add scripts/org-patrol tests/test_org_scripts.sh README.md
git commit -F /tmp/c-commit.txt
```

---

## Self-Review

**Spec coverage:** A idempotent autofix → Task 1. B verification/merge-queue + `autofix_failed` signal → Task 2. C patrol enablement + docs → Task 3. Safety invariants: never-merges (no `gh pr merge` anywhere; a test asserts it); CI-only autonomous (Task 3 recommends `fix-ci-apply`); allowlist/branch/source rails inherited from `_triage_apply_fix` (unchanged); only ralph's own PRs (search `ralph-fix in:body`); idempotent (marker/label/comment existence checks).

**Placeholder scan:** none — every code/test step is complete. The spec's "verify counts in the soak summary" is delivered at the log/report level in Task 3; promoting it to an asserted soak-summary JSON field is a small optional follow-up (mirrors the existing `resource` block) and is called out here rather than left as a hidden TODO.

**Type consistency:** `_triage_apply_fix … finding_key` (arg 9) defined in Task 1, not re-signatured later. `triage_verify_fixes repo [apply]` defined in Task 2, invoked by the patrol in Task 3 via `triage --verify-fixes`. Markers `ralph-fix:` / `ralph-verified` / `ralph-fix-failed` and the label `ralph-ready` are spelled identically across all tasks.
