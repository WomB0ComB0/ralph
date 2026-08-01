# Ralph: Autonomous Up To The Merge (Design)

- **Date:** 2026-07-31
- **Status:** Approved (brainstorming), pending implementation plan
- **Scope:** Three stacked PRs (A → B → C). Makes ralph's cross-repo autofix run **unattended** and hand the operator a trustworthy, ready-to-merge queue — while stopping at every safety boundary it stops at today.

## Goal & trust boundary

The operator wants ralph "fully autonomous." The deliberate decision (not "autonomy: yes/no" but *where the trust boundary sits*) is: **autonomous up to the merge.** Ralph observes → decides what to fix → fixes → verifies → opens a PR, all without asking, on an explicit allowlist. It **stops at the merge button** and at anything security/outward-facing. A human merges.

This preserves every hard-won safety lesson in the project (e.g. "security-CI merges are the owner's call"; "for outward-facing writes confirm the specific action"; the auto-resolve-reviews regression where an agent "fixed" a review by deleting the requested change).

```
patrol tick →  scan findings
            →  [A] open a CI-fix PR   (idempotent: one per finding; skip if one is already open)
            →  [B] verify ralph's own open fix PRs against their CI
                     green → label `ralph-ready`      (the operator's clean merge queue)
                     red   → flag "fix did not hold"  (+ record a signal); never re-spam
            →  STOP.  A human merges.
```

## Non-negotiable safety invariants (preserved from today)

1. **Never merges.** Ever. The boundary is the merge button.
2. **CI-autofix only in the autonomous path, not security.** Autonomous mode opens `--fix-ci` PRs (build failures). `--fix-security` stays human-triggered.
3. **Allowlist-scoped.** Only repos in `RALPH_ORG_CODE_WRITE_TARGETS`; `ralph/fix-*` branches only; never a default branch; source-only filtering (all existing rails inherited from `_triage_apply_fix`).
4. **Only touches ralph's own PRs.** Verification labels/comments only on PRs ralph opened (identified by the `ralph-fix:` marker), never a human's PR.
5. **Idempotent everywhere.** A tick never duplicates a PR, a label, a comment, or a signal.

## Current gaps (grounded in the code)

- **No dedup.** `_triage_apply_fix` (`lib/triage.sh`) opens a PR with a per-*run* branch name (`ralph/fix-ci-<run-id>`) and never checks for an existing open fix PR. On a timer it re-opens a fresh PR every tick — PR spam is the #1 blocker to autonomy.
- **No PR verification.** Nothing reads an opened PR's CI (`statusCheckRollup`/`mergeable`). Ralph opens a fix PR and walks away, so the operator still reviews from scratch whether the fix even works.

---

## PR A — Idempotent autofix (foundation)

**Problem:** repeated autofix runs duplicate PRs.

**Design:**
- A **stable finding-key** per finding, stamped as a marker in the PR body: `<!-- ralph-fix:<kind>:<key> -->`.
  - `--fix-ci` → `kind=ci`, `key=<owner/repo>` — at most **one open ralph CI-fix PR per repo** at a time.
  - `--fix-security` → `kind=sec`, `key=<alert-number>` — one PR per alert.
- At the **top of `_triage_apply_fix`** (before the clone + agent run), query for an existing open PR carrying that marker:
  `gh pr list --repo <repo> --state open --search "ralph-fix:<kind>:<key> in:body" --json number --jq '.[0].number // empty'`.
  If a match exists → log `already has open fix PR #N` and **return early with zero work** (no clone, no agent, no PR).
- The marker is embedded in the PR **body** on creation so future ticks find it.
- **Interface change:** `_triage_apply_fix` gains a `finding_key` argument (the `<kind>:<key>` string). Callers `triage_autofix_ci` / `triage_autofix_security` compute and pass it. Dry-run output also shows the dedup decision.

**Tests (`tests/test_triage.sh`, stubbed `gh`):** an existing open marker-matching PR → autofix skips early (no `gh pr create`, no clone); no existing PR → proceeds; the created PR body carries the correct `ralph-fix:` marker; the key is per-repo for CI and per-alert for security.

**Safety:** all existing `_triage_apply_fix` rails unchanged; dedup only *suppresses* work, never adds a write.

---

## PR B — PR verification / merge queue (the payoff)

**New:** `triage_verify_fixes <repo> [apply]` + CLI `ralph triage --verify-fixes` (+ a per-repo loop through `_triage_map_targets`).

**Behavior:** list ralph's own open fix PRs (`gh pr list --repo <repo> --state open --search "ralph-fix: in:body" --json number,headRefName,statusCheckRollup,labels`). For each:
- **all checks green + mergeable** → add label `ralph-ready` (create the label once if missing, idempotent) + a one-time comment (marker `<!-- ralph-verified -->`). This is the operator's merge queue: `gh pr list --label ralph-ready`.
- **any check FAILURE** → the fix did not hold → remove `ralph-ready` if present, comment once (marker `<!-- ralph-fix-failed -->`), and record an `autofix_failed` **signal** (compounds into signals/mine/lint). **Never auto-close, never re-open.**
- **pending/none** → skip; the next tick re-checks.

- **Dry-run default** (prints `verify: N ready, M failing, K pending`); `--apply` performs the label/comment writes. Every write is marker-guarded → re-running never spams.
- **Never merges.** Transient `gh` failures degrade like the rest of triage (rc 75 → defer, preserve state).

**Tests:** green PR → labelled `ralph-ready` + verified marker, idempotent on re-run; red PR → label removed + fail marker + `autofix_failed` signal; pending → untouched; dry-run writes nothing; only marker-carrying (ralph-own) PRs are touched.

---

## PR C — Autonomous enablement (tie it together)

- `scripts/org-patrol`: after any `*-apply` fix pass, also run `triage --verify-fixes --apply` on `RALPH_ORG_CODE_WRITE_TARGETS`. Each tick then: (1) idempotently opens CI-fix PRs for new failures, (2) verifies all open ralph fix PRs → grows `ralph-ready`, (3) flags reds.
- **Recommended autonomous config: `RALPH_ORG_TRIAGE_MODE=fix-ci-apply`** (CI only). `fix-security-apply` remains for deliberate human-driven runs, not the recommended unattended mode.
- Add the verify result (`ready`/`failing` counts) to the patrol **soak summary** JSON for observability.
- README: an "Autonomous up to the merge" section documenting the config, the boundary, and the `ralph-ready` merge queue.

**Tests (`tests/test_org_scripts.sh`):** an apply-mode patrol runs the verify pass; the soak summary carries the verify counts; report/suggest modes do **not** run it.

---

## Rollout

Three PRs, stacked A → B → C, each bash-native, shellcheck-clean, TDD'd against the existing stubbed-`gh` harness. Default behavior is unchanged until the operator sets `RALPH_ORG_TRIAGE_MODE=fix-ci-apply` + `RALPH_ORG_CODE_WRITE_TARGETS`. Adversarial review before each merge, per project workflow. No CI-merge is ever automated — the whole point is that the operator's only remaining action is the merge itself.

## Known bash gotchas to honor (from project memory)

- `[[ -z $x ]] && x=$(cmd)` is `set -e`-exempt — use `[[ -n $x ]] || x=$(cmd) || { err; }`.
- `mapfile < <(proc-subst)` doesn't propagate the subshell exit — capture first.
- `local -a x` left empty is unbound under `set -u` — `local -a x; x=()` on separate lines.
- Commit via `git commit -F <file>` (the pre-bash hook false-blocks list-style `-m` messages).
- `gh` calls go through `_triage_gh_or_transient` for the rc-75 transient-defer contract.
