# Ralph Audit: Loop Engineering Maturity Report

> Generated 2026-06-28 via an 8-dimension multi-agent audit (analyze → adversarial verify → synthesize),
> measuring Ralph against the modern two-layer / durable-orchestration / shared-artifact loop-engineering paradigm.

## 1. Reframe

Ralph is an ambitious, carefully-built **2024-era outer loop** that spends most of its engineering budget reimplementing the **inner harness the runtimes now own for free**. Against the two-layer model, Ralph inverts the modern division of labor: instead of letting the agent runtime (`claude` / `opencode` / `amp`) own context compaction, tool memory, plan mode, and sub-agents inside a persistent session, Ralph kills the session every turn (`run_ai_tool` invokes `claude ... "$prompt"` with no `--resume`/`--session`, `lib/engine.sh:675/679`) and hand-rolls a monolithic system prompt rebuilt from scratch (`generate_system_prompt`, `lib/engine.sh:528-642`), a static head/grep "windowing" of one file (`load_plan_context`, `lib/engine.sh:720-745`), and CLI-string task decomposition (`bd create/ready/close`). Where it touches the *durable-orchestration* model, it has the right instincts but none of the primitives: the "loop" is a counted `for i in $(seq ... MAX_ITERATIONS)` with `sleep 2` (`lib/engine.sh:1123/1151`), durability is a single integer in `checkpoint.txt` (`save_checkpoint`, `lib/utils.sh:583-599`), and the "orchestrator" (`soo`) is a synchronous bash script joining children with bare `wait` (`lib/tools.sh:1454/1479/1482`). The genuinely modern bets are real but isolated: a grounded artifact directory, a schema'd Beads/Dolt task substrate, and verification gating. The verdict: **Ralph reinvents the inner loop and is missing the three layers that actually define where loop engineering went — durable step execution, triggers/decision-making, and cross-loop compounding.**

## 2. Maturity Scorecard

| Dimension | Level (0-5) | One-line verdict |
|---|---|---|
| Inner agent loop (context/tools/decomp/verify) | **2** | Structured prompts + external-state gating, but fights the runtime by re-deriving state via stateless one-shots. |
| Outer loop: triggers, scheduling, what-next | **2** | Counted for-loop with a Beads readiness graph; no trigger surface, no decision-maker step. |
| Durable execution & crash recovery | **2** | Coarse whole-iteration resume; no step checkpoints, idempotency, retry, or onFailure. |
| State & artifact system | **3** | Real durable task+doc store with cross-project memory; no signals, no dedup, minimal linking. |
| Cross-loop compounding | **2** | Durable primitives exist (genetic memory, event bus) but serve one engineering domain; no linked LOG, no contracts. |
| Self-improvement & orchestration-awareness | **2** | Reactive in-session reflexion + write-only metrics; no review loop, no skill authoring, no cron. |
| Observability & trust | **2** | Right primitives (JSONL metrics, SQLite bus) but no run_id, no per-step input/output traces. |
| Concurrency, safety & blast radius | **1** | Unsafe-by-default (permission bypass on host) with a non-functional safe mode (read-only mount + `--network none`). |

## 3. What Ralph Gets Right (bets the paradigm validates)

- **Durable external state over conversation history.** Source of truth lives in the filesystem, git, the plan file, and the Beads DB, so each invocation is recoverable. This is a defensible reading of the Ralph technique and the correct instinct for surviving restarts (`main` state setup, `lib/engine.sh:1086-1090`).
- **A near-frontier `/tasks` artifact.** Beads gives schema'd records, a real `open/in_progress/blocked/closed` lifecycle (`verify_beads_complete`, `lib/engine.sh:1787-1807`), a dependency DAG (`--deps`), and **optional Dolt time-travel** with per-iteration commits (`commit_task_state`, `lib/engine.sh:1722-1730`). Plan-as-projection (`sync_plan_file` regenerates `ralph_plan.md` from the DB, `lib/engine.sh:1812-1830`) avoids hand-edited-todo drift.
- **Verification is genuinely gated, not vibes.** Completion blocks on an external task count, anticipating "verification is the trust layer" (`verify_beads_complete` gate at `lib/engine.sh:1004-1020`). Closed-loop runtime checks (`cargo check`/`ruff`/`go vet`/health probes, `verify_runtime`, `lib/engine.sh:1496-1592`) feed concrete errors forward as `NEXT_INSTRUCTION`.
- **Real reflexion on real signals.** Stall detection via `compute_project_hash` before/after and loop detection via a tail-log md5 form a genuine *within-session* closed loop (`lib/engine.sh:854/974-984`, `generate_stalling_instruction`/`generate_loop_instruction`).
- **Cross-tool portability.** One harness drives `claude`, `opencode`, and `amp` — "swap the model, the loop keeps running" is partly realized at the tool layer.
- **A HOME-global, already-consumed memory channel.** `recall_lessons` injects prior lessons into *every* prompt (`lib/engine.sh:896-897`) — Ralph independently arrived at "read prior lessons before working." The plumbing is right; only the payload is impoverished.
- **Security instincts where the sandbox is actually used.** When invoked, the Docker path is well-hardened: read-only rootfs, `--cap-drop=ALL`, non-root user, memory/cpu/pids caps, env allowlist with regex validation (`lib/tools.sh:790-822`).

## 4. Where Ralph Is Behind

### 4a. The loop is a counter, not a trigger (structural)
The primary loop is `for i in $(seq "$start_iter" "$MAX_ITERATIONS")` with `sleep 2` (`lib/engine.sh:1123/1151`), default 10 (`lib/utils.sh:495`), `exit 1` on cap. A repo-wide grep finds zero cron/systemd/timer/inotify/webhook/`--watch`/`--once`. **For unattended operation there is no activation surface** — a human launches it and it runs a preset number of times. The Beads readiness graph that *could* drive a drain loop exists (`get_ready_tasks`, `lib/engine.sh:1780`) but the default iteration never consumes it; `load_plan_context` greps markdown checkboxes instead. There is no decision-maker step that ranks the backlog by value/effort.

### 4b. No durable step execution (structural)
Recovery is a single integer written *after* the LLM call (`save_checkpoint`, `lib/engine.sh:992`; failure path returns at `:950` before it). A mid-iteration crash replays the entire opaque agent invocation — the bare-while-loop failure the durability paradigm warns against. Worse, a transient LLM failure is **indistinguishable from "not done yet"** (both `return 1`), so `main` logs "Continuing..." and silently skips the work item with no retry (`lib/engine.sh:1141-1151`). No `step.run()` checkpoint, no per-step retry, no idempotency key (`hi_create_task` mints a new id every call; `emit_event` blindly INSERTs), no `onFailure` hook (`cleanup_ralph` only deletes temp files, `lib/utils.sh:188-205`). Recovery state beyond the integer (`LAZY_STREAK`, `PREVIOUS_LOG_HASH`, queued `NEXT_INSTRUCTION`) is hard-reset on every start (`lib/engine.sh:1102-1105`) — **the harness forgets the fix it was about to apply.**

### 4c. Single-domain, not compounding (structural)
"Swarm" is engineering sub-agents of *one* task; `soo` hard-codes planner/engineer/tester (`lib/tools.sh:1453-1483`). There are no per-domain folders/triggers/goals, no global `LOG.md`, and no per-loop README contracts. The genetic-memory payload is a single canned string — `"Project 'X' completed successfully with N iterations"` (`lib/engine.sh:1011`) — with no schema, no links, no dedup, and capture **only on success**. The SQLite event bus is durable in storage but **discarded in use**: `consume_events` reads only the last 2 minutes (`lib/tools.sh:965`) and `bus.db` is never replayed or correlated. The substrate for `/signals` exists and is thrown away.

### 4d. No review loop; the feedback edge is missing (structural)
`log_metrics` writes one JSONL line per iteration (`lib/engine.sh:989`), but the *only* readers are `benchmark.sh` and the root `benchmark_analyzer.py`, run manually. No engine path reads `metrics.json` back. Every adaptation knob is a frozen literal — `lazy_streak >= 2` (twice, `lib/engine.sh:756/918`), `max_backoff=60`, memory cap 50, the dev-port list. The prompt even advertises a `save_memory` tool (`lib/engine.sh:575`) **that is not implemented anywhere**. Ralph records its own performance and is structurally incapable of using it.

### 4e. No observability/trust surface (structural)
There is **no `run_id`** anywhere (grep-confirmed); `LOG_FILE`/`METRICS_FILE` are single shared paths (`lib/utils.sh:512-513`), so successive same-branch runs collapse into one undifferentiated file — you cannot answer "what ran at 3am and why." The assembled prompt (the step's *input*) is measured but never persisted. Per-step output goes to an anonymous `mktemp` purged at exit (`lib/engine.sh:831`); the only survivor is interleaved, undelimited, in the shared log. The `tokens` metric is a char-heuristic of the prompt only — output tokens and real cost are never captured. No iteration→commit-SHA linkage. `progress.log` is a start banner that is never appended to.

### 4f. Unsafe by default with a non-functional safe mode (correctness/safety)
The out-of-box `./ralph.sh` runs with every gate removed on the host: `amp --dangerously-allow-all`, `claude --dangerously-skip-permissions --permission-mode bypassPermissions` (`lib/engine.sh:669/675`), copilot `--allow-all` (`lib/tools.sh:588`). `SANDBOX_MODE` defaults false (`lib/utils.sh:496`). The *only* safe mode is broken: the sandbox mounts the repo **read-only** (`-v $project_dir:/app:ro`, `lib/tools.sh:793`) and sets `--network none` (`lib/tools.sh:796`) — so a code-editing agent cannot edit, and cannot reach its LLM endpoint or push. **The safe path cannot do the job, forcing operators onto the unsafe host path; all the hardening is dead code.** No working-tree singleton lock (`main` acquires none), so a cron overlap corrupts `.ralph/state`, `checkpoint.txt`, the plan, and the task DB. With near-empty `.gitignore` (25 bytes) and no secret scanner anywhere, an agent acting on the AGENTS.md "you MUST git push" mandate can stage and push a `.env`/key off-machine unsupervised. No kill-switch — the loop runs a destructive pattern to `MAX_ITERATIONS`.

*(Note: the analyst's `git add .` exfiltration data-flow is mislocated — `git_commit_task` (`lib/tools.sh:336`) is dead code and Ralph's own bash issues no `git push`. The risk is real but flows through the **LLM's** bypassed-permission tool use, not Ralph's code.)*

## 5. Target Architecture

**KEEP (the validated core):** grounded artifacts in `.ralph/artifacts`, the Beads/Dolt task substrate with time-travel, verification gating, role prompts, and cross-tool portability. These are genuinely ahead of most harnesses.

**DELEGATE to the inner tool instead of reimplementing:**
- **Session continuity.** Persist a session id in `run_ai_tool` (`lib/engine.sh:654-713`) and pass `claude --resume <id>` / `opencode run --session <id>`. Build the full `generate_system_prompt` only on iteration 1; thereafter send a short delta (new `NEXT_INSTRUCTION`, latest `verify_runtime` errors, changed `bd ready`). This single move lets the runtime's native context compaction own the inner loop and **collapses four gaps at once** — lost cross-turn reasoning, the monolith rebuild, the missing compression, and the AGENTS.md double-injection.
- **Decomposition/sub-agents.** Lean on the runtime's native plan mode / TODO / sub-agent primitives rather than CLI-string `bd` outsourcing and OS-process spawning.

**ADD (the layers that define the modern paradigm):**
- **Trigger + decision-maker.** A `--once` mode so external cron/systemd owns cadence, plus flip the primary loop to `while ! verify_beads_complete && [[ $i -le $MAX_ITERATIONS ]]` (reusing the `soo` drain pattern, `lib/tools.sh:1462`), demoting `MAX_ITERATIONS` to a runaway cap. Insert `select_next_focus()` that ranks `get_ready_tasks` (`lib/engine.sh:1780`) into a single `<focus_task>`.
- **Durable step execution.** Write a "started iteration N" marker (with `LAZY_STREAK`/`PREVIOUS_LOG_HASH`/`NEXT_INSTRUCTION` as JSON) *before* `run_ai_tool`; decompose `execute_iteration` into checkpointed steps (build_prompt/call_llm/validate/commit); wrap the LLM call in bounded backoff + an `onFailure` event; add idempotency keys to `hi_create_task`/`emit_event`.
- **A schema'd signal/ticket/task/doc store.** Add `.ralph/artifacts/signals/` and a `record_signal()` beside `emit_event` writing `{type, observation, evidence, possible_causes, suggested_action, sources[], frequency, first_seen, last_seen, tags[]}` with **theme-key dedup** (the first dedup primitive in the codebase). Add a global, artifact-linked `LOG.md` (read last 5-10 before work, append after) and version-controlled per-domain `loops/<domain>/README.md` contracts.
- **A cron review loop.** `review_run()` reads `metrics.json` + failure-tagged lessons and writes `.ralph/state/tuning.json`; `load_config` reads it so `lazy_streak >= 2` becomes `${LAZY_THRESHOLD:-2}`. Ship `ralph review` + a sample systemd timer.
- **Run-history/observability.** Give every run a `RUN_ID` and per-run dir (`runs/$RUN_ID` with a `latest` symlink); persist per-step `{prompt.txt, output.txt, meta.json}`; capture real tokens via JSON output mode and the commit SHA per step.
- **Safe-by-default.** Make the sandbox read-write (worktree/copy) with a scoped egress allowlist (LLM endpoint + git remote), default `SANDBOX_MODE=true` when non-interactive, gate the dangerous flags behind explicit opt-in, add a working-tree `flock` singleton, replace `git add .` with allowlist staging + a `gitleaks` pre-push scan.

## 6. Prioritized Roadmap

### NOW (correctness + safety — these block unattended operation)
| Change | Effort | Impact | Touches |
|---|---|---|---|
| Make the sandbox functional (RW mount + egress allowlist replacing `--network none`) and default it on for non-TTY runs; gate dangerous flags behind opt-in | M | High | `run_in_sandbox` `lib/tools.sh:762-839`; `load_config` `lib/utils.sh:496`; `run_ai_tool` `lib/engine.sh:654-686` |
| Distinguish LLM failure from "not done": add bounded backoff retry around `run_ai_tool`; emit an `iteration_failed` event instead of silent "Continuing..." | S | High | `lib/engine.sh:948-951/1150`, reuse backoff `lib/tools.sh:1459-1471` |
| Checkpoint *before* the LLM call + persist `LAZY_STREAK`/`PREVIOUS_LOG_HASH`/`NEXT_INSTRUCTION` as JSON | S | High | `save_checkpoint` `lib/utils.sh:583`; `lib/engine.sh:992/1102-1105` |
| Working-tree singleton `flock` in `main()`; allowlist staging + secret scan before any commit/push; expand `.gitignore` | S | High | `main` `lib/engine.sh:1028`; `.gitignore` |
| Gate runtime/artifact verifiers as real acceptance gates (don't return COMPLETE on a failing `cargo check`) | M | High | `verify_runtime` `lib/engine.sh:1496-1592`; completion gate `lib/engine.sh:1004-1013` |

### NEXT (close the structural feedback + trigger gaps)
| Change | Effort | Impact | Touches |
|---|---|---|---|
| `--once` mode + flip primary loop to `while ! verify_beads_complete`, `MAX_ITERATIONS` as safety cap | S | High | `lib/engine.sh:1123`; `parse_arguments` `lib/utils.sh:~900` |
| `RUN_ID` + per-run dir for log/metrics/checkpoint/steps; add `run_id` to metric line | S | High | `load_config` `lib/utils.sh:504-514`; `lib/engine.sh:989` |
| `review_run()` reads `metrics.json` → `tuning.json`; replace hardcoded `lazy_streak>=2` literals with `${LAZY_THRESHOLD:-2}` | M | High | end of `main` `lib/engine.sh:1152`; `lib/engine.sh:756/918` |
| Capture failure lessons with schema `{type, outcome, project_hash}` from reflexion + max-iter branches | S | High | `store_lesson` `lib/engine.sh:1667`; call sites `:918-924/1154-1164` |
| Persist per-step input+output traces (copy `temp_output` before cleanup) | M | High | `execute_iteration` `lib/engine.sh:948-957`/`831` |
| Session continuity: persist/resume runtime session id, send deltas after iter 1 | M | High | `run_ai_tool` `lib/engine.sh:654-713` |
| De-dup AGENTS.md (point `AGENTS_FILE` elsewhere or drop one slot); make `load_plan_context` a real compressor | S/M | Med | `lib/engine.sh:864/886/720-745` |

### LATER (the compounding moat)
| Change | Effort | Impact | Touches |
|---|---|---|---|
| `record_signal()` + `.ralph/artifacts/signals/` with theme dedup; route event bus + memory through it | M | High | beside `emit_event` `lib/tools.sh:934`; `store_lesson` `lib/engine.sh:1667` |
| Global linked `LOG.md` (read last 5-10, append with task-id/file links each iteration) | S | High | post-iteration `lib/engine.sh:998-1001`; `load_plan_context` `lib/engine.sh:720` |
| Per-domain `loops/<domain>/README.md` contracts; parameterize `soo` by domain/role-set | M | Med | `spawn_agent` `lib/tools.sh:1101`; `soo` `lib/tools.sh:1447` |
| Harden `soo` into a bounded scheduler: semaphore, per-task retry, `onFailure`, cancel-on-parent-exit, run-history | L | Med | `handle_swarm_command` `lib/tools.sh:1447-1485`; reap dead-`RUNNING` agents `lib/tools.sh:1070/1078` |
| Guarded skill authoring (`author_skill()` writes `SKILL.md` on recurring deduped lessons) + `ralph skills` approve/delete | L | Med | scan dir `lib/engine.sh:906`; new dispatch `lib/engine.sh:1030-1043` |
| Cron review/digest that correlates `bus.db` + `metrics.json` with outcomes | M | Med | `benchmark_analyzer.py` (repo root); new `review` command |

## 7. The Hard Truth

The maintainer's strategic call is to **stop spending engineering on the inner harness the runtimes already own** — the monolithic prompt rebuild, the head/grep windowing, the CLI-string decomposition, the stateless one-shot session-killing — and let `claude`/`opencode` carry the inner loop via a persisted session. Every hour spent improving Ralph's hand-rolled context assembly is an hour competing with the tool vendors and losing. The moat, per Nadella, **is the loop, not the model**: it lives in the layers Ralph is weakest at — durable step-checkpointed execution with idempotency and `onFailure`, real triggers and a decision-maker, and a deduplicated shared-artifact system with a global `LOG.md` that lets domain loops compound and "learn while you sleep." Ralph already has the rarest and hardest piece — a durable, versioned task/doc substrate (Beads/Dolt) — so the path is addition, not rewrite. But none of it matters until the **safe path is the functional path**: today the only working configuration runs an unsandboxed agent with all permission gates removed on the operator's host, which is disqualifying for the unattended autonomy Ralph is built to deliver.
