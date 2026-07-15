# Ralph Enterprise Hardening Handoff

Last verified: 2026-07-14 (America/New_York)

## Start Here

| Item | State |
|---|---|
| Working branch | `feat/synapse-hookup` |
| Base branch | `main` |
| Last implementation commit | `e25fedd` (`Contain executors in supervised process groups`) |
| Pull request | [#40: Harden autonomous execution and Synapse integration](https://github.com/WomB0ComB0/ralph/pull/40) |
| PR state at handoff | Draft, mergeable, GitGuardian passing |
| Local baseline | 21 suites / 655 assertions passing |

Do not restart this work from `main`. Continue on `feat/synapse-hookup` unless the
repository owner asks for a smaller follow-up branch.

```bash
git switch feat/synapse-hookup
git pull --rebase
export PATH="$PATH:/home/wombocombo/go/bin"
bd ready
```

The branch already contains the Synapse client and console, local Ollama agents,
dynamic model selection, the asynchronous Jules adapter, completion and quality
gates, durable run manifests, crash recovery, cleanup evidence, and supervised
executor process groups. Do not reimplement those pieces.

## Remaining Work

Recommended order:

1. Fix sandbox credential disclosure (`ralph-0gv`, P1).
2. Add mandatory CI (`ralph-5gt`, P2).
3. Run the real Jules smoke (`ralph-lmc`, P3) when credentials and a disposable
   connected source are available.
4. Implement retained-run cleanup statistics (`ralph-qbt`, P4). This can proceed
   while Jules access is blocked.
5. Run final gates, update PR #40, and take it out of draft.

### 1. `ralph-0gv`: Redact Sandbox-Forwarded Secrets

Why this is P1: `run_in_sandbox` in `lib/tools.sh` currently appends custom
allowlisted variables to Docker arguments as `-e NAME=value`, then debug-logs the
complete argument list. A credential forwarded with `RALPH_SANDBOX_ALLOW_ENV`
can therefore appear in logs and Docker CLI process arguments.

Start with:

```bash
bd update ralph-0gv --claim
```

Acceptance requirements:

- Prefer Docker's name-only inheritance form (`-e NAME`) so the value is not
  embedded in the constructed CLI arguments.
- Log allowlisted variable names only. Suppressing the current debug line alone
  is insufficient because the secret would remain in the Docker CLI argv.
- Preserve the existing rejection of `PATH`, shell-loader variables, and invalid
  identifiers.
- Add a sentinel-secret fixture proving the value reaches the selected sandbox
  fixture but never appears in logs, persisted artifacts, or rendered commands.
- Run the full suite and `tests/sandbox_provisioning_smoke.sh`.

Until this issue is closed, do not use `RALPH_SANDBOX_ALLOW_ENV` for credentials.

### 2. `ralph-5gt`: Add Mandatory CI Quality Gates

Why this remains: PR #40 currently has only a GitGuardian check. Ralph has no
tracked `.github/workflows` directory, so its full test gate is local-only.

Start with:

```bash
bd update ralph-5gt --claim
```

Acceptance requirements:

- Add a GitHub Actions workflow for pull requests and pushes to `main`.
- Use least-privilege permissions (`contents: read` unless a job proves it needs
  more), bounded job timeouts, and concurrency cancellation.
- Install the documented Bash, `jq`, `bc`, SQLite, Python, Git, and process-tool
  dependencies.
- Run Bash syntax checks, Python compilation, and `./tests/run_all.sh`.
- Check the committed PR range for whitespace errors using the event base SHA;
  a bare `git diff --check` on a clean Actions checkout checks nothing.
- Never call a real model provider and never require AI, Jules, Synapse, or GitHub
  write credentials.
- Decide whether `tests/sandbox_provisioning_smoke.sh` belongs in a separate
  Docker job. Document the choice and keep the core test job hermetic.
- Record the resulting required-check name so a repository administrator can add
  it to branch protection.

After the workflow runs on PR #40, inspect the logs rather than treating a green
badge as sufficient. Close the issue with the workflow run URL and test total.

<!-- Self-benchmarking: measure full-suite wall time in CI before adding caches or sharding. -->

### 3. `ralph-lmc`: Run a Real Jules Provider Smoke

Current blocker: as of 2026-07-13, neither `JULES_API_KEY` nor
`RALPH_JULES_SOURCE` was present. Hermetic provider tests pass 22/22, but no live
Jules session has been created.

Security constraint: Jules is a remote cloud executor. Use a disposable,
non-proprietary connected repository unless the owner explicitly approves sending
the target repository and task to Jules. Keep the API key only in the environment
or a secret store; never put it in `.ralphrc`, logs, fixtures, commits, or this
document.

When prerequisites exist:

```bash
bd update ralph-lmc --claim

# Load JULES_API_KEY through the approved secret store, then fail closed if absent.
: "${JULES_API_KEY:?load JULES_API_KEY from the approved secret store}"
export RALPH_JULES_SOURCE="sources/github-owner-repo"
export RALPH_JULES_STARTING_BRANCH="ralph-jules-smoke"
export RALPH_JULES_TIMEOUT=900
```

Prepare one bounded task in the disposable target repository and run PR mode:

```bash
RALPH_JULES_MODE=pr \
  /home/wombocombo/github/dev/ralph/ralph.sh \
  --tool jules --once --unattended --no-sandbox
```

The explicit host mode is intentional until `ralph-0gv` is fixed. Run it only in
the disposable repository, and review that repository's verification commands
before patch mode can execute them.

Verify the matching `.ralph/runs/<run-id>/providers/jules.json` contains a stable
`sessionName`, terminal `state`, `mode: "pr"`, and `pullRequestUrl`. Resume the
same Ralph task once and confirm it reuses the session instead of creating a
second Jules job.

Then use a fresh disposable branch for patch mode:

```bash
RALPH_JULES_MODE=patch \
  /home/wombocombo/github/dev/ralph/ralph.sh \
  --tool jules --once --unattended --no-sandbox
```

Verify the patch is applied locally against the expected base commit, the target
repository tests pass, and Jules state records `patchApplied: true`. If the live
API shape differs from fixtures, update `lib/jules.sh` and
`tests/test_jules_provider.sh`; do not add one-off parsing in the engine.

Close `ralph-lmc` only after both PR and patch modes have evidence. Record session
IDs or public disposable PR URLs, but no prompts, source contents, or credentials.

### 4. `ralph-qbt`: Aggregate Cleanup Latency Across Runs

The per-run source is `.ralph/runs/<run-id>/process-cleanup.json`, written by
`_ralph_record_process_cleanup_event` in `lib/processes.sh`. Its allowlisted v1
events contain only:

```text
kind:        provider | live_smoke
trigger:     normal | timeout | quiescence | verification | signal | exit | parent_death
outcome:     already_exited | term | kill
duration_ms: integer from 0 through 86400000
finished_at: UTC timestamp
```

Start with:

```bash
bd update ralph-qbt --claim
```

Implementation requirements:

- Add a read-only operator command dispatched before model dependency checks in
  `main()`; keep aggregation logic outside the iteration engine.
- Read only retained run artifacts under the configured Ralph run root.
- Strictly validate `schema_version: 1`, artifact type, event fields, ranges, and
  enums. Skip malformed artifacts safely and expose only a bounded skipped count.
- Report sample count, p50, p95, and maximum duration plus TERM/KILL rates,
  separated by `provider` and `live_smoke`.
- Choose and document a deterministic integer percentile convention, such as
  nearest-rank, then lock it down with fixtures.
- Do not collect or print commands, PIDs, paths outside the run root, prompts,
  logs, environment values, or secrets. Avoid following untrusted symlinks.
- Add a dedicated test suite covering valid aggregation, malformed files, empty
  input, retention boundaries, percentile edges, kind separation, and redaction.
- Register the suite in `tests/run_all.sh` and update `tests/README.md` and the
  operator documentation.

The self-benchmark comment immediately above
`_ralph_record_process_cleanup_event` points to this task.

## Non-Negotiable Invariants

- One Ralph task maps to one Jules session. Resume persisted state; do not create
  one remote session per iteration.
- Run manifests, Jules state, cleanup evidence, and soak reports remain mode
  `600`, bounded, allowlisted, and free of credentials and prompt contents.
- The guardian must be running before a supervised child is released from its
  handshake. Keep PID/start-token/PPID/PGID/SID validation intact.
- Process groups provide lifecycle ownership, not hostile-code isolation. Use the
  Docker sandbox for untrusted local executors.
- `Dockerfile.ralph` is generated and ignored. Change its tracked generator in
  `lib/tools.sh`, not only the generated file.
- Work with unrelated user changes; never reset or discard them.

## Validation Baseline

Before this handoff, these passed:

- `./tests/run_all.sh`: 21 suites, 655 assertions.
- `tests/test_processes.sh`: 48 assertions.
- `tests/test_ai_tools.sh`: 122 assertions.
- `tests/test_jules_provider.sh`: 22 assertions.
- Seeded soak: 2 cycles, 4 TERM/KILL faults, 0 failures, 6/6 retention.
- Docker provisioning/supervisor smoke under non-root, read-only-root, and
  capability-dropped execution.

Run the complete final gate after code changes:

```bash
bash -n ralph.sh lib/*.sh tests/*.sh scripts/*
python3 -m py_compile lib/process_supervisor.py lib/ollama_agent.py
./tests/run_all.sh
tests/unattended_soak.sh --cycles 2 --duration 120 --seed 42 \
  --output /tmp/ralph-final-soak.json
tests/sandbox_provisioning_smoke.sh
git diff --check
```

An increased assertion count is expected when new tests are added. No existing
case should disappear without a documented reason.

## Finish and Transfer

For each issue:

```bash
bd close <issue-id> --reason "Implemented ...; validation ..."
```

Before ending every session, follow `AGENTS.md` exactly:

```bash
git pull --rebase
scripts/bd-sync-compat
git push
git status                    # must say up to date with origin
git remote prune origin
```

Also verify there are no session-created stashes or temporary worktrees. Update
PR #40 with the final test totals and external smoke evidence. Mark it ready for
review only after all available required checks pass; if Jules credentials remain
unavailable, leave `ralph-lmc` open and state that limitation explicitly rather
than claiming live validation.
