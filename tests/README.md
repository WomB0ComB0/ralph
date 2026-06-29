# Ralph tests

Run everything:

```bash
./tests/run_all.sh
```

Exit code is `0` only if every suite passes. Each suite is hermetic — it sources
`lib/*.sh` directly and uses its own `mktemp` sandboxes, so nothing touches your
working tree.

## Suites

| File | Covers |
|------|--------|
| `test_now_tier.sh` | Durability + safety: retry/backoff, recovery state, failure-≠-done + circuit breaker, sandbox, secret scan, flock singleton (21 cases) |
| `test_next_tier.sh` | Triggers + observability + self-tuning: `--once`, backlog-drain, RUN_ID/run dirs, `review_run`, lazy-threshold recommendation (14) |
| `test_lists.sh` | Configurable excludes + list defaults: `hash_exclude_names`, health-port / model-family / sandbox-env overrides, `gitdiff-exclude` (12) |
| `test_signals.sh` | Signal + LOG.md compounding: `theme_key` normalization/dedup, lifecycle (open/ack/resolved, regressed-reopen), bounded recall, prune, co-occurrence (`related`) links (39) |
| `test_skills.sh` | Guarded skill-authoring: candidate→approved guard, auto-capture, ranked recall, synthetic-note rejection, **cross-project (global) skills** (32) |
| `test_swarm.sh` | Bounded swarm scheduler: live-PID active count, dead-agent reaping, slot-gating, run-history (9) |
| `test_lint.sh` | Knowledge-lint curator pass: gaps / orphaned / stale / approval-backlog / high-severity, quiet mode (12) |
| `test_ai_tools.sh` | AI-tool command builder (`_build_ai_cmd`): per-tool invocation for opencode / claude / amp / agy, headless flags, stdin vs positional, subshell-scoped env (16) |
| `run_internal_tests.sh` | Wrapper for the native `ralph --test` (the suite embedded in `lib/tools.sh`, 17 cases) |

## Writing tests

These are plain bash assertion harnesses (no framework). A suite sources the libs,
sets up a temp sandbox, and prints `TOTAL: N passed, M failed`. Follow TDD: add a
failing assertion first, watch it fail, then implement. New library behavior should
land with a matching case here (or in the native `run_internal_tests` in
`lib/tools.sh` when it needs the full runtime).
