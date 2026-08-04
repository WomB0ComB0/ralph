# Autofix resilience: scratch-fs monitor + circuit-breaker + quality gate

**Date:** 2026-08-03
**Status:** Approved (design)
**Related:** PR #69 (opencode `TMPDIR` off the RAM tmpfs — root-cause fix)

## Problem

The autonomous `resq-software` patrol ran with a healthy timer and reported
`band=normal ok=true` while producing **zero fixes**: 177/177 autofix attempts
died with `provider_failure: tool exited 74` (opencode emitting zero bytes when
`/tmp` — a 16G RAM tmpfs — exhausted). Two independent weaknesses let this hide
behind a green dashboard:

1. **The resource monitor was blind to the scratch filesystem.** It measures the
   `.ralph` runs directory (`disk=24.6M`) but never `/tmp` (the filesystem that
   was actually full), so nothing ever flipped the band off `normal`.
2. **The autofix loop had no circuit-breaker.** `_triage_map_targets` retried
   each repo, swallowed the outcome (`|| true`), and moved on — so an
   *environmental* fault common to every repo produced 177 identical silent
   failures instead of one loud "stop, this is the environment" signal.

PR #69 fixes the root cause. Parts A and B make the **class** of failure
observable and self-limiting, so a future environmental fault surfaces on the
first run instead of churning invisibly.

A separate weakness surfaced when the loop *did* start producing PRs again:
**fix quality is highly variable**. Hand-review of three `ralph-ready` PRs
found one surgical, correct fix (viz #143: a one-line `bun.lock` re-sync to a
patched `postcss`) alongside two that reached green CI without fixing anything:

- **dotnet-sdk #84** — 910 files / +29k lines, almost entirely committed
  `bin/Release` + `obj/Release` **build artifacts**, "resolving" a
  duplicate-code check by brute force.
- **docs #116** — a **new, empty `.lycheecache`** for a "broken external links"
  failure: it suppresses/caches the check without repairing a single link.

The trust boundary (human merges) caught these, but nothing in the loop flags
them. Part C adds a quality gate so bad-but-green fixes are rejected before a PR
is ever opened.

Non-goals: cross-tool (opencode→claude) provider fallback — it would not help a
shared-`/tmp` fault (all tools write scratch there) and is out of scope. A
provider "can it write a byte" preflight is deferred (noted as future work).

## A. Scratch-filesystem awareness (`lib/resources.sh`)

The snapshot built by `handle_resource_report_command` gains a
`.system.scratch` block describing the filesystem backing `$TMPDIR`
(default `/tmp`):

```json
"scratch": {
  "path": "/tmp",
  "used_percent": 81.3,
  "inode_used_percent": 47.6
}
```

- Measured with `df -kP "$dir"` (bytes) and `df -iP "$dir"` (inodes); `dir` is
  `${TMPDIR:-/tmp}`. If `df` is unavailable or the path can't be resolved, the
  fields are `null` and no warning is emitted (fail-open — never block a run on
  a measurement gap).
- New budget `RALPH_RESOURCE_MAX_SCRATCH_PCT`, **default 90**. When *either*
  `used_percent` or `inode_used_percent` exceeds it, emit
  `warn("scratch", "system.scratch.used_percent" | "system.scratch.inode_used_percent", observed, limit, message)`.
- Consequence: band is derived as "normal iff zero warnings", so a saturated
  `/tmp` now yields `band=warning ok=false` — the "green while dying" blind spot
  is closed with no new band-derivation logic.

The budget is added to the existing `--max-*` CLI/env plumbing alongside
`max_memory_used_percent`, following the established pattern exactly.

## B. Autofix circuit-breaker (`lib/triage.sh`)

### Classified outcome

`triage_autofix_ci` (and `triage_autofix_security`) return a **distinct exit
code** for a provider failure so the caller can classify the result without
re-parsing evidence files:

- `0` — success / opened a PR / no-op skip (already has an open PR) / no CI
  failures. (Existing "nothing wrong" and "did work" both stay 0.)
- `RALPH_TRIAGE_RC_PROVIDER_FAILURE` — the agent provider failed to produce a
  usable result (`outcome == provider_failure`). Defined as a named constant, not
  a bare literal (see "rc collision" below).

No-change outcomes (agent ran, produced nothing) stay `0`: they are not an
environmental signal and must not trip the breaker.

### The breaker

`_triage_map_targets` tracks a running count of **consecutive** provider
failures across successive repos:

- On a target returning the provider-failure rc: `consecutive++`.
- On any other rc (including success and no-change): `consecutive=0`.
- When `consecutive >= RALPH_AUTOFIX_BREAKER_THRESHOLD` (**default 3**): **trip**.

Tripping:
1. **Stops attempting further autofix targets this run** (the loop breaks; the
   remaining repos are logged as skipped-by-breaker with a count).
2. Records an `autofix_circuit_open` **signal** (via the standard signal writer)
   carrying the shared reason and the repos involved, so it appears in
   `signals`/`mine`.
3. Logs a loud `ERROR`: the shared failure reason + a remediation hint
   ("N consecutive provider failures — likely environmental, e.g. exhausted
   scratch fs; not a per-repo bug").

Tripping does **not**:
- Abort verify, memory-sync, or the resource report — those run normally after
  the (short-circuited) autofix phase.
- Change the process exit code — the patrol still exits 0 so the systemd timer
  keeps ticking. The degradation is surfaced via the signal + the soak-summary,
  and (when the cause is scratch exhaustion) via the band=warning from part A.

### Threshold rationale

Three *consecutive* failures across *different* repos is the signature of an
environmental fault; a single repo's transient provider hiccup (1) or an
unlucky pair (2) should not stop the run. The threshold is env-tunable.

### rc collision note

`_triage_apply_fix` already uses an internal `rc75` for fail-closed fix-dedup.
The classified provider-failure rc for `triage_autofix_ci` must not collide with
that internal meaning at the loop boundary. Implementation defines
`RALPH_TRIAGE_RC_PROVIDER_FAILURE` as a named constant and confirms (test) that
`triage_autofix_ci` maps only the `provider_failure` outcome to it, and that the
dedup path returns a different, non-tripping code. Pick an unused code in the
64–113 `sysexits` range (candidate: 69 `EX_UNAVAILABLE`); the constant, not the
literal, is what the loop compares. Part C adds a second, distinct constant
`RALPH_TRIAGE_RC_QUALITY_REJECT` — the two must not collide with each other or
with the internal `rc75`.

## C. Autofix quality gate (`lib/triage.sh`)

`_triage_apply_fix` already keeps a fix "source-only" via a **path denylist**
(reverting `package.json`, lockfiles, `.github/`, and the self-control surface
at lines ~714–723). A denylist must be extended forever and silently misses new
categories — which is how #84's `bin/`/`obj/` artifacts reached a PR. Part C
adds an **assertion on the final staged changeset**, evaluated *after* the
existing source filter and *before* commit/push/PR. It fails safe: if the diff
looks pathological, no PR is opened.

Reject the fix if any rule fails:

- **R1 — scope budget.** Reject if the changeset touches more than
  `RALPH_AUTOFIX_MAX_FILES` (**default 25**) files or more than
  `RALPH_AUTOFIX_MAX_LINES` (**default 800**) changed lines. A CI fix is
  surgical; a 910-file / +29k-line diff is pathological. (Blocks #84.)
- **R2 — build-artifact / ignored paths.** Reject if any changed path is
  (a) matched by the target repo's own ignore rules (`git check-ignore`), or
  (b) under a known build-output directory (`bin/`, `obj/`, `node_modules/`,
  `dist/`, `build/`, `target/`, `.venv/`, `__pycache__/`, `.next/`,
  `coverage/`), or (c) has a build-artifact extension (`.dll`, `.exe`, `.pdb`,
  `.class`, `.o`). (Blocks #84 with certainty.)
- **R3 — no-op / empty suppression.** Reject if the effective diff is empty or
  its only additions are newly-created **empty** files. (Flags #116's empty
  `.lycheecache`.)

On rejection:
1. **No commit / push / PR.** The workspace is discarded as usual.
2. Record an `autofix_rejected` **signal** (`reason=budget|artifact|noop`, repo,
   file/line counts) so it appears in `signals`/`mine`.
3. Log a loud `WARNING` naming the rule and the offending paths/counts.
4. Return `RALPH_TRIAGE_RC_QUALITY_REJECT` — a **distinct** classified rc that is
   NOT the provider-failure code, so a bad-but-non-environmental fix does **not**
   increment the Part B circuit-breaker's consecutive-failure counter.

Verified against the three hand-reviewed PRs: viz #143 (+1/−1 `bun.lock`, a
non-empty existing file) passes all three rules; dotnet-sdk #84 fails R1 and R2;
docs #116 fails R3. Good surgical fixes are not over-blocked.

The gate augments — does not replace — the existing source-only denylist.

## Testing (TDD, RED→GREEN)

**`tests/test_resource.sh`**
- `.system.scratch` block present with `path`, `used_percent`,
  `inode_used_percent`.
- Over-budget scratch (stub `df` / inject a low budget) emits a `scratch`
  warning and drops `ok` to false.
- Under-budget scratch emits no warning.
- Missing `df` / unresolvable path → `null` fields, no warning (fail-open).

**`tests/test_triage.sh`**
- `triage_autofix_ci` returns the provider-failure rc when the outcome is
  `provider_failure`, and `0` on success / no-change / already-open-PR.
- `_triage_map_targets` trips at the threshold: with a stubbed `fn` returning
  the provider-failure rc, the loop stops after N and does not call `fn` for
  later targets.
- A non-failure result resets the consecutive counter (2 fails, 1 success, 2
  fails → no trip).
- Tripping records the `autofix_circuit_open` signal.
- Verify/memory phases are unaffected by a tripped breaker.

**`tests/test_triage.sh` — quality gate (Part C)**
- R1: a changeset over the file budget and one over the line budget are each
  rejected; a small diff under both passes.
- R2: a path under `bin/`/`obj/` (and a `git check-ignore`-matched path) is
  rejected; an artifact extension is rejected.
- R3: an empty-file-only addition is rejected; a modification to an existing
  non-empty file (the #143 shape) passes.
- A rejected fix opens **no PR**, records the `autofix_rejected` signal, and
  returns `RALPH_TRIAGE_RC_QUALITY_REJECT`.
- The reject rc is distinct from the provider-failure rc and does **not**
  increment the circuit-breaker counter (a rejected fix followed by more
  rejections never trips the environmental breaker).

Full suite must stay green (run with `TMPDIR` on disk to avoid tmpfs-exhaustion
noise in the harness itself).

## Delivery

One PR, branch `feat/autofix-circuit-breaker-scratch-monitor`, base `main`,
covering all three parts (A scratch monitor, B circuit-breaker, C quality gate).
Independent of PR #69 (no file overlap: #69 touches `lib/engine.sh` +
`tests/test_ai_tools.sh`; this touches `lib/resources.sh`, `lib/triage.sh`,
`tests/test_resource.sh`, `tests/test_triage.sh`).

Parts B and C both add classified return codes to the autofix path and both are
tested in `test_triage.sh`; keeping them in one PR avoids splitting the rc
constants and the `_triage_map_targets` boundary across two changes.
