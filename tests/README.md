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
| `test_next_tier.sh` | Triggers + observability + self-tuning: `--once`, backlog-drain, RUN_ID/run dirs, `review_run`, lazy-threshold recommendation, entry-point dep-gate deferral, `--version`, `RALPH_UNATTENDED` mapping (20) |
| `test_loop_guards.sh` | Pure loop guard predicates: stall ceilings, run budget ceilings, and backlog-drain completion gate enforcement (23) |
| `test_lists.sh` | Configurable excludes + list defaults: `hash_exclude_names`, health-port / model-family / sandbox-env overrides, `gitdiff-exclude`, project-hash cache invalidates on uncommitted changes (14) |
| `test_signals.sh` | Signal + LOG.md compounding: `theme_key` normalization/dedup, lifecycle (open/ack/resolved, regressed-reopen), bounded recall, prune, co-occurrence (`related`) links (39) |
| `test_skills.sh` | Guarded skill-authoring: candidate→approved guard, auto-capture, ranked recall, synthetic-note rejection, **cross-project (global) skills** (32) |
| `test_swarm.sh` | Bounded swarm scheduler: live-PID active count, dead-agent reaping, slot-gating, run-history (9) |
| `test_lint.sh` | Knowledge-lint curator pass: gaps / orphaned / stale / approval-backlog / high-severity, quiet mode (13) |
| `test_quality_gate.sh` | Durable `QUALITY.md` rubric creation, prompt injection, and `Quality Gate: pass` completion policy (11) |
| `test_ai_tools.sh` | AI-tool command builder (`_build_ai_cmd`): per-tool invocation for opencode / claude / amp / agy / codex, headless flags, stdin vs positional, subshell-scoped env, agy flag-order + --model, per-call timeout, codex (exec/sandbox), tool validity, stderr/stdout capture separation, claude fallback/budget/auth, opt-in session resume (`--continue`) + `_should_resume` gating, agy `--add-dir` cwd binding, tool-aware `resolve_agents_file` (CLAUDE.md vs AGENTS.md, strict override) (80) |
| `test_models.sh` | Dynamic model resolution (`_pick_latest_model`/`resolve_model_for_tool`): newest-per-role from a live list, claude alias, amp/codex self-select, agy `agy models`, determine_model source precedence, param-count guard, alias validation (16) |
| `test_fallback.sh` | Smart model management: `classify_tool_failure` (rate-limit/overload/quota/auth/timeout), `build_model_chain` (primary + fallbacks, local-first, dedup), `preferred_local_model`, `run_ai_with_fallback` graceful degradation, non-sticky, stderr classify, real provider payloads + exit/signal codes (128+N range), rc guard (46) |
| `test_triage.sh` | Cross-repo read-only GitHub triage: allowlist parsing (env + `ralph.targets`, dedup/comments), gh-JSON parsers for failing CI + Dependabot/code-scanning/secret-scanning, severity ranking, error-object guard, CI-autofix safety gates (26) |
| `test_memory.sh` | Genetic memory: `<memory>…</memory>` extraction from agent output, `store_lesson` dedup + defensive init, `recall_lessons` read-back, null-safety (13) |
| `run_internal_tests.sh` | Wrapper for the native `ralph --test` (the suite embedded in `lib/tools.sh`, 18 cases) |

## Writing tests

These are plain bash assertion harnesses (no framework). A suite sources the libs,
sets up a temp sandbox, and prints `TOTAL: N passed, M failed`. Follow TDD: add a
failing assertion first, watch it fail, then implement. New library behavior should
land with a matching case here (or in the native `run_internal_tests` in
`lib/tools.sh` when it needs the full runtime).
