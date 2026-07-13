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
| `test_now_tier.sh` | Durability + safety: retry/backoff, recovery state, failure-≠-done + circuit breaker, Docker sandbox args and explicit `flock` provisioning, secret scan, flock singleton (36 cases) |
| `test_next_tier.sh` | Triggers + observability + self-tuning: `--once`, backlog-drain, RUN_ID/run dirs, `review_run`, lazy-threshold recommendation, entry-point dep-gate deferral, `--version`, `RALPH_UNATTENDED` mapping, and explicit sandbox CLI precedence (23) |
| `test_run_manifest.sh` | Durable run lifecycle: allowlisted schema, permissions, atomic and serialized monotonic heartbeats, lock contention fallback, progress, explicit outcomes, resume lineage, stale-run reconciliation, unexpected exits, and HUP/INT/TERM handling (54) |
| `test_processes.sh` | Owned-process cleanup: procfs/command child discovery, descendant-aware TERM/KILL escalation, mandatory PID-identity guards, parent-death cleanup, mode-`600` bounded and sanitized allowlisted evidence, and summaries (26) |
| `test_loop_guards.sh` | Pure loop guard predicates: stall ceilings, run budget ceilings, and backlog-drain completion gate enforcement (23) |
| `test_runtime_verification.sh` | Runtime verification: safe declared command discovery/execution, timeout evidence, opt-in live smoke, cleanup evidence, and project-owned health-port checks (21) |
| `test_lists.sh` | Configurable excludes + list defaults: `hash_exclude_names`, health-port / model-family / sandbox-env overrides, `gitdiff-exclude`, project-hash cache invalidates on uncommitted changes (14) |
| `test_signals.sh` | Signal + LOG.md compounding: `theme_key` normalization/dedup, lifecycle (open/ack/resolved, regressed-reopen), bounded recall, prune, co-occurrence (`related`) links (39) |
| `test_skills.sh` | Guarded skill-authoring: candidate→approved guard, auto-capture, ranked recall, synthetic-note rejection, **cross-project (global) skills** (32) |
| `test_swarm.sh` | Bounded swarm scheduler: live-PID active count, dead-agent reaping, slot-gating, run-history (9) |
| `test_lint.sh` | Knowledge-lint curator pass: gaps / orphaned / stale / approval-backlog / high-severity, quiet mode (13) |
| `test_quality_gate.sh` | Durable `QUALITY.md` rubric creation, prompt injection, and `Quality Gate: pass` completion policy (11) |
| `test_ai_tools.sh` | AI-tool command builder and execution lifecycle: per-tool invocation for opencode / claude / amp / agy / codex, headless flags, stdin vs positional, scoped env, timeout/quiescence behavior, output normalization, session resume, cleanup evidence, TERM cleanup, SIGKILL parent-death guarding, and singleton-lock release (115) |
| `test_jules_provider.sh` | Jules remote executor: payload modes, persisted session reuse, PR completion output, and patch-mode local apply with fixture API calls (22) |
| `test_models.sh` | Dynamic model resolution (`_pick_latest_model`/`resolve_model_for_tool`): newest-per-role from a live list, claude alias, amp/codex self-select, agy `agy models`, determine_model source precedence, param-count guard, alias validation (18) |
| `test_fallback.sh` | Smart model management: `classify_tool_failure` (rate-limit/overload/quota/auth/timeout), `build_model_chain` (primary + fallbacks, local-first, dedup), `preferred_local_model`, `run_ai_with_fallback` graceful degradation, non-sticky, stderr classify, real provider payloads + exit/signal codes (128+N range), rc guard (46) |
| `test_triage.sh` | Cross-repo read-only GitHub triage: allowlist parsing (env + `ralph.targets`, dedup/comments), gh-JSON parsers for failing CI + Dependabot/code-scanning/secret-scanning, severity ranking, error-object guard, CI-autofix safety gates (58) |
| `test_memory.sh` | Genetic memory: `<memory>…</memory>` extraction from agent output, `store_lesson` dedup + defensive init, `recall_lessons` read-back, null-safety (13) |
| `test_agents.sh` | Synapse client and per-agent live probes with hermetic HTTP and CLI fixtures (31) |
| `test_ollama_agent.sh` | Local Ollama agent tool loop with a fake HTTP server, premature-finish rejection, and bounded file writes (4) |
| `run_internal_tests.sh` | Wrapper for the native `ralph --test` (the suite embedded in `lib/tools.sh`, 18 cases) |

## Writing tests

These are plain bash assertion harnesses (no framework). A suite sources the libs,
sets up a temp sandbox, and prints `TOTAL: N passed, M failed`. Follow TDD: add a
failing assertion first, watch it fail, then implement. New library behavior should
land with a matching case here (or in the native `run_internal_tests` in
`lib/tools.sh` when it needs the full runtime).

## Optional unattended soak

`tests/unattended_soak.sh` runs the real entry point in a disposable Git repository with local fixture executors. Each seeded cycle injects TERM and KILL, resumes from a checkpoint, checks process cleanup, cleanup evidence, and stale-run reconciliation, verifies retention, and emits a mode-`600` JSON report without calling a model provider.

```bash
tests/unattended_soak.sh --cycles 2 --duration 120 --seed 42 \
  --output /tmp/ralph-soak.json
```

## Optional Docker smoke

`tests/sandbox_provisioning_smoke.sh` exercises the Docker sandbox image with a
stubbed selected AI tool. It requires Docker, builds `ralph-sandbox:latest` if
missing, and does not call a real model provider.
