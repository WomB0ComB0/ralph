# Autofix circuit-breaker + scratch-filesystem resource check

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

PR #69 fixes the root cause. This change makes the **class** of failure
observable and self-limiting, so a future environmental fault surfaces on the
first run instead of churning invisibly.

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
literal, is what the loop compares.

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

Full suite must stay green (run with `TMPDIR` on disk to avoid tmpfs-exhaustion
noise in the harness itself).

## Delivery

One PR, branch `feat/autofix-circuit-breaker-scratch-monitor`, base `main`.
Independent of PR #69 (no file overlap: #69 touches `lib/engine.sh` +
`tests/test_ai_tools.sh`; this touches `lib/resources.sh`, `lib/triage.sh`,
`tests/test_resource.sh`, `tests/test_triage.sh`).
