# `ralph mine` — Failure-Mining Meta-Loop (Design)

- **Date:** 2026-07-30
- **Status:** Approved (brainstorming), pending implementation plan
- **Scope:** One new module (`lib/mine.sh`), one CLI verb (`ralph mine`), one `review_run` one-liner, one test suite (`tests/test_mine.sh`), README + native `--test` wiring.

## Problem

Ralph accumulates rich per-iteration failure telemetry in a JSONL run ledger
(`${METRICS_FILE:-${STATE_DIR:-.ralph/state}/metrics.json}`) — one line per
iteration across *all* runs, with `run_id, iteration, tool, model, latency,
tokens, tokens_total, lazy_streak, changed, verify_ok, project_hash`, plus
per-iteration provider summaries carrying `provider_failure` outcomes and
reasons. **Nothing reads this ledger back.**

The existing compounding layers do not cover this:

- `signals.sh` records failures *during* a run (handler-driven, within-run).
- `lint.sh` curates the *signal/skill store* — it never touches the ledger.

The unique, unfilled value is **cross-run, ledger-driven** analysis: cluster
failing iterations, detect recurrence and regressions over time, compound the
findings, and (opt-in) propose a fix. This is the "failure-mining meta-loop over
the JSONL ledger" long deferred in the project direction notes.

## Non-goals

- No new dedup engine — reuse `record_signal`'s `theme_key` mechanism.
- No new code-fix engine — reuse `_triage_apply_fix`.
- No auto-merge, no push to a default branch, no unattended code writes without
  an explicit escalation flag.
- Not a replacement for `signals`/`lint`/`triage`; it feeds them.

## Architecture

A new module `lib/mine.sh` with three **escalating, opt-in** stages. Read-only
is the default; each stage past the first is an explicit flag.

```
metrics.json (all runs)
      |  (1) MINE  - read-only, always
      v
 ranked failure-theme digest ----------------> stdout / review_run one-liner
      |  (2) FEED  - --feed
      v
 record_signal (ledger_failure family, deduped) --> signal->skill->recall->lint
      |  (3) PROPOSE - --propose [--apply]
      v
 _triage_apply_fix(repo, default, ralph/mine-fix-<hash>, prompt, ..., apply)
      v
 dry-run plan (default) OR source-only PR vs default branch (--apply)
```

### Stage 1 — Mine (always, read-only)

Slurp `metrics.json` across all runs with a single-slurp `jq` pass and a
per-line fallback on malformed lines (mirrors `signals.sh` robustness; a corrupt
line must never abort the pass). A **failing iteration** is classified into
exactly one kind, in priority order (first match wins):

| Kind | Detected from (metrics.json fields) | Meaning |
|---|---|---|
| `stall` | `lazy_streak >= RALPH_MINE_STALL` | sustained no-progress |
| `verify_fail` | `verify_ok == false` | agent completed but verification failed |
| `no_progress` | `changed == false` | iteration burned with no file changes |
| `token_blowup` | `tokens` above `RALPH_MINE_TOKEN_P` percentile | cost anomaly on an otherwise-clean iteration |

> **Why no `provider_failure` kind:** a model-chain-exhaustion iteration
> `return 2`s at `engine.sh:1947`, *before* `log_metrics` (2069) — so it never
> writes a `metrics.json` row. It already self-records a high-severity
> `task_repeat_failure` signal at runtime (`engine.sh:1938`). Mining it from the
> ledger is impossible and would double-count what signals already capture, so
> it is intentionally excluded. The four kinds above are exactly the failure
> states that reach the durable ledger.

**Theme key** = `<kind>:<tool>:<model-tier>`, where the model is normalized to
its tier (e.g. `opus-4-8-*` and `opus-*` collapse to `opus`) so grouping is
stable across pinned model IDs. The theme key is both the grouping unit and the
seed for `record_signal`'s `theme_key` in Stage 2.

Per theme, compute: `frequency`, `distinct_runs`, `first_seen`, `last_seen`, a
representative reason string, and a **regression flag** (recent-window failure
rate vs prior baseline rate).

**Ranking (severity score):** `frequency × cross_run_spread × recency_weight`,
multiplied by a regression factor when the recent-window rate exceeds baseline.
The digest prints the top `RALPH_MINE_TOP` (default 5) themes: kind, tool/model,
count, #runs, last-seen, a regression marker, and the representative reason.

### Stage 2 — Feed (`--feed`)

For each theme meeting the feed threshold — `frequency >= RALPH_MINE_MIN_FREQ`
(default 3) **and** `distinct_runs >= 2` — call `record_signal` in a
`ledger_failure` family with the mining theme key. Dedup and lifecycle are
entirely the existing `record_signal`/`theme_key` machinery (idempotent on
re-run). No new state. Because these become ordinary signals, `lint`'s
KNOWLEDGE-GAP curator surfaces them automatically, and a resolution can be
captured as a skill through the normal path.

The two-part threshold is the safety property: **one bad run never compounds; a
pattern across >=2 distinct runs does.**

### Stage 3 — Propose (`--propose [--apply]`)

Take the single **top** recurring theme. Build a fix prompt from its evidence
(failure kind, representative reason(s), affected tool/model tier, and a short
ledger excerpt). Resolve the current project's GitHub slug via
`gh repo view --json nameWithOwner -q .nameWithOwner` (the `github.sh` helper).
Then:

```
_triage_apply_fix "$repo" "$default_branch" "ralph/mine-fix-<theme-hash>" \
    "$prompt" "$title" "$body" "$apply" "mine:<kind>"
```

- **Dry-run is the default** (`apply=0`): prints the clone/branch/PR plan, no
  side effects. `--apply` sets `apply=1`.
- All `_triage_apply_fix` rails are inherited: throwaway worktree, source-only
  filtering, `_triage_safe_push_branch` (never pushes to default), RETURN-trap
  cleanup, transient-failure deferral.

**Guards:**

- If the current project is not a GitHub repo (slug resolution fails), Stage 3
  logs a clean skip and returns 0 — mining and feeding still work.
- If the project *is* the ralph repo itself, `_triage_strip_self_control_surface`
  (already in the triage path) prevents the agent from editing
  `lib/`, `ralph.sh`, `scripts/`, or the config allowlist.
- Stage 3 never runs without an explicit `--propose`; `--apply` is required to
  leave dry-run.

## CLI surface

- `ralph mine` — read-only ranked digest (default).
- `ralph mine --feed` — digest + record deduped `ledger_failure` signals.
- `ralph mine --propose` — digest + dry-run code-fix plan for the top theme.
- `ralph mine --propose --apply` — as above, but actually open the source-only
  `ralph/mine-fix-*` PR vs the default branch.
- `review_run` emits a one-liner: `mine: N recurring themes (top: <kind> xF/Rruns)`.

Flags compose (`--feed --propose` is valid). Dispatched in `engine.sh main()`
next to `signal`/`skill`/`lint`/`triage`, and treated as a read-only subcommand
for dependency-check ordering (like `lint`).

## Configuration knobs

| Env var | Default | Purpose |
|---|---|---|
| `RALPH_MINE_MIN_FREQ` | 3 | min theme frequency to feed a signal |
| `RALPH_MINE_WINDOW` | 50 | recent-window size (iterations) for regression rate |
| `RALPH_MINE_BASELINE` | 200 | prior-window size for baseline rate |
| `RALPH_MINE_TOP` | 5 | themes shown in the digest |
| `RALPH_MINE_STALL` | 3 | `lazy_streak` threshold for the `stall` kind |
| `RALPH_MINE_TOKEN_P` | 95 | percentile for `token_blowup` |

(Defaults chosen so a first, small ledger produces a quiet digest and no signals
until a genuine cross-run pattern exists.)

## Testing

**`tests/test_mine.sh`** (scratchpad-TDD first, then committed) over a fixture
`metrics.json` with synthetic mixed iterations. Assertions:

1. Theme aggregation groups by `<kind>:<tool>:<model-tier>` with tier collapse.
2. Severity ranking orders themes correctly.
3. `min-freq` + `distinct_runs>=2` filtering (a single-run pattern is excluded).
4. Regression detection fires when recent-window rate exceeds baseline.
5. `--feed` records deduped signals and is **idempotent** across re-runs.
6. `--propose` dry-run prints the plan and performs **no** clone/push
   (stub `gh`/`git` on PATH; assert they are not invoked destructively).
7. Repo-slug guard: a non-GitHub fixture → clean skip, exit 0.
8. Malformed ledger line → per-line fallback, pass does not abort.

**Native `--test`:** a mine smoke registered under the `set -e`/`set -u` path
(the unit harness runs `set +eu`, so a native regression guard is required to
catch set-e-only aborts — same lesson as `lint`/`signals`).

## Known bash gotchas to honor (from project memory)

- `[[ -z $x ]] && x=$(cmd)` is `set -e`-exempt (AND-OR list) — a failing `cmd`
  silently continues. Use `[[ -n $x ]] || x=$(cmd) || { err; exit 1; }`.
- `mapfile < <(proc-subst)` does not propagate the subshell exit — capture to a
  var first.
- Commit the design/impl via `git commit -F <file>` (the pre-bash hook
  false-blocks inline `-m` messages containing `- ` list lines or flag-like
  tokens).
- `local -a x` left empty is unbound under `set -u`; use `local -a x; x=()`.

## Rollout

Single PR (`feat/ralph-mine-failure-mining`), bash-native, shellcheck-clean,
opt-in-escalating, dry-run-default. No CI in the ralph repo, so the PR is the
user's to review/merge. Adversarial review before push, per project workflow.
