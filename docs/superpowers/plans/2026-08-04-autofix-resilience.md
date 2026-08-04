# Autofix Resilience Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make ralph's autofix loop observe and self-limit environmental failures (scratch-fs monitor + circuit-breaker) and reject bad-but-green fixes before they open PRs (quality gate).

**Architecture:** Three independent additions on the autofix path. (A) `lib/resources.sh` gains a `.system.scratch` block + budget so a full `$TMPDIR` filesystem flips the resource band off `normal`. (B) `lib/triage.sh` returns a classified provider-failure rc; `_triage_map_targets` trips after N consecutive provider failures. (C) `_triage_apply_fix` asserts on the final staged diff (scope budget, artifact/ignored paths, no-op) and rejects with a distinct rc that does not trip the breaker.

**Tech Stack:** Bash 3.2-compatible shell, `jq`, `git`, `df`; the repo's own test harnesses (`tests/test_resource_report.sh`, `tests/test_triage.sh`) with `ok/bad/eq` assertions.

## Global Constraints

- Bash 3.2 compatible (no `wait -n`, no associative-array requirement, no `${x^^}`); libs run under `set -euo pipefail`, tests under `set +eu`.
- Fail-open for observability (Part A) — a measurement gap must never block a run; fail-safe for the gate (Part C) — an unmeasurable diff is rejected, not merged.
- Return codes: `0`=success/skip, `1`=hard error, `75`=transient/deferred (RESERVED — do not reuse). New: `RALPH_TRIAGE_RC_PROVIDER_FAILURE=69`, `RALPH_TRIAGE_RC_QUALITY_REJECT=65`. All four distinct.
- Signals via `record_signal <kind> <summary> <detail> <suggestion> <source> [severity] [origin]`, always guarded by `declare -F record_signal >/dev/null 2>&1 && ... || true`.
- Run the full suite with `TMPDIR=~/.cache/ralph/tmp` (disk) so tmpfs pressure doesn't cause spurious `mktemp` failures in the harness.
- Defaults: `RALPH_RESOURCE_MAX_SCRATCH_PCT=90`, `RALPH_AUTOFIX_BREAKER_THRESHOLD=3`, `RALPH_AUTOFIX_MAX_FILES=25`, `RALPH_AUTOFIX_MAX_LINES=800`. Lockfile basenames: `uv.lock package-lock.json bun.lock pnpm-lock.yaml yarn.lock poetry.lock Cargo.lock Gemfile.lock composer.lock go.sum flake.lock` (env-extend via `RALPH_AUTOFIX_LOCKFILE_NAMES`).

---

### Task 1: Part A — scratch-filesystem awareness in the resource report

**Files:**
- Modify: `lib/resources.sh` (new helper `_resource_scratch_json`; budget parse; jq wiring for `.system.scratch`, `.budgets.max_scratch_used_percent`, and two `scratch` warnings)
- Test: `tests/test_resource_report.sh`

**Interfaces:**
- Produces: `_resource_scratch_json()` → `{"path":<str>,"used_percent":<int|null>,"inode_used_percent":<int|null>}`. New CLI flag `--max-scratch-pct N` on `handle_resource_command report`, env `RALPH_RESOURCE_MAX_SCRATCH_PCT` (default 90).

- [ ] **Step 1: Write the failing tests** — append to `tests/test_resource_report.sh` (after the existing budget tests, before the summary section):

```bash
echo "== scratch filesystem awareness =="
# scratch block is always present
out=$(handle_resource_command report)
jq -e '.system.scratch | (has("path") and has("used_percent") and has("inode_used_percent"))' <<<"$out" >/dev/null \
  && ok "report includes a system.scratch block" || bad "missing system.scratch: $out"
# budget default surfaces (90) and is a number
out=$(handle_resource_command report)
jq -e '.budgets.max_scratch_used_percent == 90' <<<"$out" >/dev/null \
  && ok "scratch budget defaults to 90" || bad "scratch budget default wrong: $(jq -c .budgets <<<"$out")"
# force an over-budget warning by setting the budget to 0 (any non-null usage exceeds it)
out=$(handle_resource_command report --max-scratch-pct 0)
jq -e '[.warnings[]?.kind] | any(. == "scratch")' <<<"$out" >/dev/null \
  && ok "over-budget scratch emits a scratch warning" || bad "no scratch warning at budget 0: $(jq -c .warnings <<<"$out")"
jq -e '.ok == false' <<<"$out" >/dev/null \
  && ok "scratch warning drops ok to false" || bad "ok not false with scratch warning"
# under budget: no scratch warning (budget 100 — nothing exceeds 100)
out=$(handle_resource_command report --max-scratch-pct 100)
jq -e '[.warnings[]?.kind] | any(. == "scratch") | not' <<<"$out" >/dev/null \
  && ok "under-budget scratch emits no warning" || bad "unexpected scratch warning at budget 100"
# invalid budget rejected
handle_resource_command report --max-scratch-pct nope >/dev/null 2>&1 \
  && bad "invalid scratch budget accepted" || ok "invalid scratch budget rejected"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `TMPDIR=~/.cache/ralph/tmp bash tests/test_resource_report.sh 2>&1 | grep -iE 'scratch|FAIL'`
Expected: FAIL on the scratch assertions (no `.system.scratch`, no budget, no warning).

- [ ] **Step 3: Add the `_resource_scratch_json` helper** — in `lib/resources.sh`, immediately after `_resource_synapse_json()` (ends ~line 59):

```bash
# Filesystem backing $TMPDIR (default /tmp). On hosts where /tmp is a RAM tmpfs this is the
# scratch surface that exhausts and silently breaks providers; the monitor watches it so a
# full scratch fs flips the band off "normal". Fail-open: unmeasurable -> null, no warning.
_resource_scratch_json() {
    local dir="${TMPDIR:-/tmp}" used="null" inode="null" v
    if command -v df >/dev/null 2>&1 && [[ -d "$dir" ]]; then
        v=$(df -kP "$dir" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5+0; f=1} END{if(!f) print "null"}')
        [[ "$v" =~ ^[0-9]+$ ]] && used="$v"
        v=$(df -iP "$dir" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5+0; f=1} END{if(!f) print "null"}')
        [[ "$v" =~ ^[0-9]+$ ]] && inode="$v"
    fi
    jq -n --arg path "$dir" --argjson used "$used" --argjson inode "$inode" \
        '{path:$path,used_percent:$used,inode_used_percent:$inode}'
}
```

- [ ] **Step 4: Parse the budget** — in `handle_resource_report_command`, next to the other budget locals (near `local max_memory_pct=...`, ~line 160):

```bash
    local max_scratch_pct="${RALPH_RESOURCE_MAX_SCRATCH_PCT:-90}"
```

Add the CLI flag in the arg-parse `case` (next to `--max-memory-used-pct`):

```bash
            --max-scratch-pct) max_scratch_pct="${2:?--max-scratch-pct requires a value}"; shift 2 ;;
            --max-scratch-pct=*) max_scratch_pct="${1#*=}"; shift ;;
```

Add validation next to the other numeric validations (near the `--max-slope-pct` check ~line 211):

```bash
    if [[ -n "$max_scratch_pct" ]] && ! _resource_is_number "$max_scratch_pct"; then
        echo "invalid --max-scratch-pct: $max_scratch_pct" >&2
        return 2
    fi
```

- [ ] **Step 5: Wire it into the main jq** — in the `report=$(jq -n ...)` block (~line 244):

Add two `--argjson` inputs (next to `--argjson synapse ...` and `--argjson max_memory_pct ...`):

```bash
        --argjson scratch "$(_resource_scratch_json)" \
        --argjson max_scratch_pct "$(_resource_budget_json_number "$max_scratch_pct")" \
```

Add `scratch` to the `system:{...}` object (line ~274) — change `system:{load:$load,memory:$memory,timers:$timers,synapse:$synapse}` to:

```
          system:{load:$load,memory:$memory,timers:$timers,synapse:$synapse,scratch:$scratch},
```

Add the budget to `budgets:{...}` (line ~275) — append `,max_scratch_used_percent:$max_scratch_pct` before the closing brace of the budgets object.

Add two warnings to the `.warnings = [ ... ]` array (after the last `trend` warning, ~line 290 — mind the comma before them):

```
             if .budgets.max_scratch_used_percent != null and .system.scratch.used_percent != null and .system.scratch.used_percent > .budgets.max_scratch_used_percent then warn("scratch";"system.scratch.used_percent";.system.scratch.used_percent;.budgets.max_scratch_used_percent;"scratch filesystem usage exceeds budget") else empty end,
             if .budgets.max_scratch_used_percent != null and .system.scratch.inode_used_percent != null and .system.scratch.inode_used_percent > .budgets.max_scratch_used_percent then warn("scratch";"system.scratch.inode_used_percent";.system.scratch.inode_used_percent;.budgets.max_scratch_used_percent;"scratch filesystem inode usage exceeds budget") else empty end
```

(The item BEFORE these must now end with a comma; these two are the new last elements.)

- [ ] **Step 6: Run the tests to verify they pass**

Run: `TMPDIR=~/.cache/ralph/tmp bash tests/test_resource_report.sh 2>&1 | tail -1`
Expected: PASS, `0 failed`.

- [ ] **Step 7: Commit**

```bash
git add lib/resources.sh tests/test_resource_report.sh
git commit -m "feat(resources): watch the scratch (\$TMPDIR) filesystem in the resource report

Add a .system.scratch block (df of \$TMPDIR: used% + inode%) and a
max_scratch_used_percent budget (default 90). A saturated /tmp now emits a
'scratch' warning that flips the band off normal — closing the blind spot that
let a full RAM tmpfs hide behind band=normal."
```

---

### Task 2: Part B — classified provider-failure return code

**Files:**
- Modify: `lib/triage.sh` (define rc constants near the top; change the agent-failure return in `_triage_apply_fix` from `1` to the provider-failure rc)
- Test: `tests/test_triage.sh`

**Interfaces:**
- Produces: globals `RALPH_TRIAGE_RC_PROVIDER_FAILURE=69`, `RALPH_TRIAGE_RC_QUALITY_REJECT=65`. `_triage_apply_fix` (and therefore `triage_autofix_ci`) returns `69` when the agent fails to produce a usable result.

- [ ] **Step 1: Write the failing test** — append to `tests/test_triage.sh` (the file already stubs `gh` and calls `triage_autofix_ci "o/r" 0`; reuse that harness). Add:

```bash
echo "== classified provider-failure rc =="
eq "provider-failure rc constant is 69" 69 "${RALPH_TRIAGE_RC_PROVIDER_FAILURE:-unset}"
eq "quality-reject rc constant is 65" 65 "${RALPH_TRIAGE_RC_QUALITY_REJECT:-unset}"
# Drive _triage_apply_fix down the agent-failure branch with a stub run_ai_tool that fails.
_tt_prov() {
    run_ai_tool() { return 3; }                      # agent "fails" (any non-zero)
    _triage_gh_or_transient() { shift 2; "$@"; }     # pass through
    gh() { case "$1 $2" in "repo clone") mkdir -p "$3"; ( cd "$3" && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m base ); return 0;; *) return 0;; esac; }
    _triage_default_branch() { echo main; }
    _triage_apply_fix "o/r" main ralph/fix-ci-1 "prompt" "t" "b" 1 "" "ci:o/r" >/dev/null 2>&1
    echo "rc=$?"
}
prov_rc=$( _tt_prov 2>/dev/null | sed -n 's/^rc=//p' )
eq "agent failure returns the provider-failure rc" "69" "$prov_rc"
```

(If the existing harness already defines a working `gh`/clone stub, reuse it instead of the inline one — keep the test's stub consistent with the file's conventions.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `TMPDIR=~/.cache/ralph/tmp bash tests/test_triage.sh 2>&1 | grep -iE 'provider-failure|quality-reject|FAIL' | head`
Expected: FAIL — constants unset; agent failure currently returns `1`, not `69`.

- [ ] **Step 3: Define the constants** — in `lib/triage.sh`, near the top after the header comment block (before the first function). Plain assignment (NOT `readonly` — the file is re-sourced by tests):

```bash
# Classified autofix return codes (distinct from 0=ok, 1=error, 75=transient/deferred).
RALPH_TRIAGE_RC_PROVIDER_FAILURE=69   # EX_UNAVAILABLE: agent provider failed to produce a usable result
RALPH_TRIAGE_RC_QUALITY_REJECT=65     # EX_DATAERR: fix diff rejected by the quality gate
```

- [ ] **Step 4: Return the classified rc on agent failure** — in `_triage_apply_fix`, the agent-failure branch (currently line ~711):

Change:
```bash
    if [[ "$ai_rc" -ne 0 ]]; then
        _triage_write_autofix_failure_diag "$repo" "$base_branch" "$branch" "$lf" "$of" "$ai_rc" "$filter_context"
        _triage_apply_fix_return 1; return $?
    fi
```
to:
```bash
    if [[ "$ai_rc" -ne 0 ]]; then
        _triage_write_autofix_failure_diag "$repo" "$base_branch" "$branch" "$lf" "$of" "$ai_rc" "$filter_context"
        _triage_apply_fix_return "$RALPH_TRIAGE_RC_PROVIDER_FAILURE"; return $?
    fi
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `TMPDIR=~/.cache/ralph/tmp bash tests/test_triage.sh 2>&1 | grep -iE 'provider-failure|quality-reject'`
Expected: PASS on all three.

- [ ] **Step 6: Commit**

```bash
git add lib/triage.sh tests/test_triage.sh
git commit -m "feat(triage): classify agent provider failure with a distinct rc (69)

_triage_apply_fix (and triage_autofix_ci, which returns its rc) now returns
RALPH_TRIAGE_RC_PROVIDER_FAILURE when the agent fails to produce a usable
result, so the circuit-breaker can distinguish an environmental provider fault
from a per-repo error. Also defines RALPH_TRIAGE_RC_QUALITY_REJECT (65) for the
quality gate."
```

---

### Task 3: Part B — circuit-breaker in `_triage_map_targets`

**Files:**
- Modify: `lib/triage.sh` (the sequential `conc==1` path of `_triage_map_targets`, ~line 1252-1255)
- Test: `tests/test_triage.sh`

**Interfaces:**
- Consumes: `RALPH_TRIAGE_RC_PROVIDER_FAILURE` (Task 2), `record_signal`.
- Produces: env `RALPH_AUTOFIX_BREAKER_THRESHOLD` (default 3). After N consecutive provider-failure rcs the sequential loop breaks early; records an `autofix_circuit_open` signal.

- [ ] **Step 1: Write the failing tests** — append to `tests/test_triage.sh` (mirrors the existing `_mt_fn` map-targets tests, ~line 769):

```bash
echo "== autofix circuit-breaker (sequential) =="
targets=(o/a o/b o/c o/d)
# fn that always returns the provider-failure rc, and logs each call
_bk_all_fail() { printf 'call %s\n' "$1" >>"$BK_LOG"; return "${RALPH_TRIAGE_RC_PROVIDER_FAILURE}"; }
BK_LOG=$(mktemp)
RALPH_AUTOFIX_BREAKER_THRESHOLD=3 RALPH_TRIAGE_CONCURRENCY=1 _triage_map_targets _bk_all_fail >/dev/null 2>&1
eq "breaker stops after the threshold (3 calls, not 4)" 3 "$(wc -l <"$BK_LOG" | tr -d ' ')"
rm -f "$BK_LOG"

# a success between failures RESETS the counter -> never trips (2 fail, 1 ok, 2 fail = 5 calls)
_bk_mixed() { printf 'call %s\n' "$1" >>"$BK_LOG"; case "$1" in o/c) return 0;; *) return "${RALPH_TRIAGE_RC_PROVIDER_FAILURE}";; esac; }
targets=(o/a o/b o/c o/d o/e); BK_LOG=$(mktemp)
RALPH_AUTOFIX_BREAKER_THRESHOLD=3 RALPH_TRIAGE_CONCURRENCY=1 _triage_map_targets _bk_mixed >/dev/null 2>&1
eq "a success resets the consecutive counter (all 5 run)" 5 "$(wc -l <"$BK_LOG" | tr -d ' ')"
rm -f "$BK_LOG"

# a non-provider-failure rc (1) does NOT count toward the breaker
_bk_err() { printf 'call %s\n' "$1" >>"$BK_LOG"; return 1; }
targets=(o/a o/b o/c o/d); BK_LOG=$(mktemp)
RALPH_AUTOFIX_BREAKER_THRESHOLD=3 RALPH_TRIAGE_CONCURRENCY=1 _triage_map_targets _bk_err >/dev/null 2>&1
eq "non-provider errors do not trip the breaker (all 4 run)" 4 "$(wc -l <"$BK_LOG" | tr -d ' ')"
rm -f "$BK_LOG"

# tripping records an autofix_circuit_open signal
targets=(o/a o/b o/c o/d)
export SIGNAL_DIR=$(mktemp -d)
RALPH_AUTOFIX_BREAKER_THRESHOLD=3 RALPH_TRIAGE_CONCURRENCY=1 _triage_map_targets _bk_all_fail >/dev/null 2>&1
grep -rql 'autofix_circuit_open' "$SIGNAL_DIR" 2>/dev/null \
  && ok "breaker records an autofix_circuit_open signal" || bad "no autofix_circuit_open signal in $SIGNAL_DIR"
rm -rf "$SIGNAL_DIR"; unset SIGNAL_DIR
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `TMPDIR=~/.cache/ralph/tmp bash tests/test_triage.sh 2>&1 | grep -iE 'breaker|circuit|FAIL' | head`
Expected: FAIL — currently all 4 targets always run; no signal.

- [ ] **Step 3: Implement the breaker** — replace the sequential branch in `_triage_map_targets` (currently):

```bash
    if [[ "$conc" -eq 1 ]]; then
        for r in "${targets[@]}"; do "$fn" "$r" ${extra[@]+"${extra[@]}"} || true; done
        return 0
    fi
```
with:
```bash
    if [[ "$conc" -eq 1 ]]; then
        local _consec=0 _rc _thr="${RALPH_AUTOFIX_BREAKER_THRESHOLD:-3}"
        [[ "$_thr" =~ ^[0-9]+$ && "$_thr" -ge 1 ]] || _thr=3
        for r in "${targets[@]}"; do
            _rc=0
            "$fn" "$r" ${extra[@]+"${extra[@]}"} || _rc=$?
            if [[ "$_rc" -eq "${RALPH_TRIAGE_RC_PROVIDER_FAILURE:-69}" ]]; then
                _consec=$((_consec + 1))
                if [[ "$_consec" -ge "$_thr" ]]; then
                    log_error "autofix circuit-breaker: $_consec consecutive provider failures — likely environmental (e.g. exhausted scratch fs, auth, connectivity), not a per-repo bug. Skipping remaining autofix targets this run."
                    declare -F record_signal >/dev/null 2>&1 && \
                        record_signal autofix_circuit_open "autofix circuit-breaker tripped after $_consec consecutive provider failures" "the agent provider failed to produce a usable result on $_consec repos in a row" "inspect the provider/environment (scratch filesystem, auth, connectivity) before the next run" "triage,autofix" high "triage" >/dev/null 2>&1 || true
                    break
                fi
            else
                _consec=0
            fi
        done
        return 0
    fi
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `TMPDIR=~/.cache/ralph/tmp bash tests/test_triage.sh 2>&1 | grep -iE 'breaker|circuit'`
Expected: PASS on all breaker assertions.

- [ ] **Step 5: Commit**

```bash
git add lib/triage.sh tests/test_triage.sh
git commit -m "feat(triage): circuit-breaker on consecutive autofix provider failures

The sequential _triage_map_targets loop (the patrol default) now counts
consecutive RALPH_TRIAGE_RC_PROVIDER_FAILURE returns and, at
RALPH_AUTOFIX_BREAKER_THRESHOLD (default 3), stops attempting further autofix
targets this run and records an autofix_circuit_open signal. Any non-provider
result resets the counter. Verify/memory/resource phases (later in the patrol)
are unaffected; exit stays 0 so the timer keeps ticking."
```

---

### Task 4: Part C — quality-gate helpers (lockfile + artifact classifiers)

**Files:**
- Modify: `lib/triage.sh` (add `_triage_is_lockfile`, `_triage_is_artifact_path`)
- Test: `tests/test_triage.sh`

**Interfaces:**
- Produces: `_triage_is_lockfile <path>` → rc 0 if the basename is a recognized lockfile. `_triage_is_artifact_path <path>` → rc 0 if the path is a build-output dir/extension. Both pure (no side effects).

- [ ] **Step 1: Write the failing tests** — append to `tests/test_triage.sh`:

```bash
echo "== quality-gate path classifiers =="
_triage_is_lockfile "src/app/uv.lock"           && ok "uv.lock is a lockfile"            || bad "uv.lock not detected"
_triage_is_lockfile "a/b/bun.lock"              && ok "nested bun.lock is a lockfile"    || bad "nested bun.lock not detected"
_triage_is_lockfile "Cargo.lock"               && ok "Cargo.lock is a lockfile"         || bad "Cargo.lock not detected"
_triage_is_lockfile "src/main.rs"              && bad "main.rs wrongly a lockfile"      || ok "main.rs is not a lockfile"
RALPH_AUTOFIX_LOCKFILE_NAMES="my.lock" _triage_is_lockfile "x/my.lock" && ok "env-added lockfile name honored" || bad "RALPH_AUTOFIX_LOCKFILE_NAMES ignored"

_triage_is_artifact_path "tests/T/bin/Release/net9.0/x.dll" && ok "bin/ path is an artifact"  || bad "bin/ not detected"
_triage_is_artifact_path "obj/Release/a.json"               && ok "obj/ path is an artifact"  || bad "obj/ not detected"
_triage_is_artifact_path "node_modules/x/y.js"              && ok "node_modules is an artifact" || bad "node_modules not detected"
_triage_is_artifact_path "src/app/main.ts"                  && bad "source wrongly an artifact" || ok "source is not an artifact"
_triage_is_artifact_path "build/lib.o"                      && ok ".o extension is an artifact" || bad ".o not detected"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `TMPDIR=~/.cache/ralph/tmp bash tests/test_triage.sh 2>&1 | grep -iE 'lockfile|artifact|FAIL' | head`
Expected: FAIL — functions undefined.

- [ ] **Step 3: Implement the helpers** — in `lib/triage.sh`, above `_triage_apply_fix` (near the other `_triage_*` helpers):

```bash
# True (rc 0) if PATH's basename is a recognized lockfile (config-of-record, legitimately
# large — exempt from the quality gate's scope budget). Extend via RALPH_AUTOFIX_LOCKFILE_NAMES.
_triage_is_lockfile() {
    local base names n
    base=$(basename -- "$1")
    names="${RALPH_AUTOFIX_LOCKFILE_NAMES:-} uv.lock package-lock.json bun.lock pnpm-lock.yaml yarn.lock poetry.lock Cargo.lock Gemfile.lock composer.lock go.sum flake.lock"
    for n in $names; do [[ "$base" == "$n" ]] && return 0; done
    return 1
}

# True (rc 0) if PATH is under a known build-output directory or has a build-artifact extension.
_triage_is_artifact_path() {
    case "$1" in
        bin/*|*/bin/*|obj/*|*/obj/*|node_modules/*|*/node_modules/*|dist/*|*/dist/*|\
        build/*|*/build/*|target/*|*/target/*|.venv/*|*/.venv/*|__pycache__/*|*/__pycache__/*|\
        .next/*|*/.next/*|coverage/*|*/coverage/*) return 0 ;;
        *.dll|*.exe|*.pdb|*.class|*.o) return 0 ;;
    esac
    return 1
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `TMPDIR=~/.cache/ralph/tmp bash tests/test_triage.sh 2>&1 | grep -iE 'lockfile|artifact'`
Expected: PASS on all.

- [ ] **Step 5: Commit**

```bash
git add lib/triage.sh tests/test_triage.sh
git commit -m "feat(triage): add lockfile + build-artifact path classifiers for the quality gate"
```

---

### Task 5: Part C — the `_triage_quality_gate` function

**Files:**
- Modify: `lib/triage.sh` (add `_triage_quality_gate`)
- Test: `tests/test_triage.sh`

**Interfaces:**
- Consumes: `_triage_is_lockfile`, `_triage_is_artifact_path` (Task 4).
- Produces: `_triage_quality_gate <work_dir> <repo>` — stages all changes (`git -C <work> add -A`), inspects `git diff --cached --numstat HEAD`. On reject: prints a one-word reason (`artifact|budget|noop`) to stdout and returns 1. On pass: prints nothing, returns 0. Env: `RALPH_AUTOFIX_MAX_FILES` (25), `RALPH_AUTOFIX_MAX_LINES` (800).

- [ ] **Step 1: Write the failing tests** — append to `tests/test_triage.sh`. Helper builds a throwaway git repo with a given change, then runs the gate:

```bash
echo "== _triage_quality_gate =="
# make a git repo with one committed base file
_qg_repo() {
    local d; d=$(mktemp -d)
    ( cd "$d" && git init -q && git config user.email t@t && git config user.name t \
      && mkdir -p src && printf 'base\n' > src/keep.txt && git add -A && git commit -q -m base ) >/dev/null 2>&1
    printf '%s' "$d"
}

# PASS: small source edit
d=$(_qg_repo); ( cd "$d" && printf 'fix\n' >> src/keep.txt )
reason=$(_triage_quality_gate "$d" o/r); rc=$?
eq "small source edit passes (rc 0)" 0 "$rc"; eq "small source edit no reason" "" "$reason"; rm -rf "$d"

# PASS: large lockfile-only diff (the #79 shape)
d=$(_qg_repo); ( cd "$d" && mkdir -p pkg && { for i in $(seq 1 3000); do echo "line $i"; done; } > pkg/uv.lock )
reason=$(_triage_quality_gate "$d" o/r); rc=$?
eq "3000-line uv.lock-only diff passes" 0 "$rc"; rm -rf "$d"

# REJECT: artifact path (the #84 shape)
d=$(_qg_repo); ( cd "$d" && mkdir -p tests/T/bin/Release/net9.0 && printf 'x\n' > tests/T/bin/Release/net9.0/a.json )
reason=$(_triage_quality_gate "$d" o/r); rc=$?
eq "bin/ artifact rejected (rc 1)" 1 "$rc"; eq "artifact reason" "artifact" "$reason"; rm -rf "$d"

# REJECT: over line budget (non-lockfile)
d=$(_qg_repo); ( cd "$d" && { for i in $(seq 1 900); do echo "l$i"; done; } > src/big.txt )
reason=$(RALPH_AUTOFIX_MAX_LINES=800 _triage_quality_gate "$d" o/r); rc=$?
eq "over line budget rejected" 1 "$rc"; eq "budget reason" "budget" "$reason"; rm -rf "$d"

# REJECT: no-op / empty new file (the #116 shape)
d=$(_qg_repo); ( cd "$d" && : > .lycheecache )
reason=$(_triage_quality_gate "$d" o/r); rc=$?
eq "empty-file-only diff rejected" 1 "$rc"; eq "noop reason" "noop" "$reason"; rm -rf "$d"

# lockfile exemption does NOT rescue an over-budget NON-lockfile change alongside a big lockfile
d=$(_qg_repo); ( cd "$d" && mkdir -p pkg && { for i in $(seq 1 3000); do echo "l$i"; done; } > pkg/uv.lock && { for i in $(seq 1 900); do echo "s$i"; done; } > src/big.txt )
reason=$(RALPH_AUTOFIX_MAX_LINES=800 _triage_quality_gate "$d" o/r); rc=$?
eq "big lockfile + over-budget source still rejected" 1 "$rc"; rm -rf "$d"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `TMPDIR=~/.cache/ralph/tmp bash tests/test_triage.sh 2>&1 | grep -iE 'quality_gate|passes|rejected|FAIL' | head`
Expected: FAIL — function undefined.

- [ ] **Step 3: Implement `_triage_quality_gate`** — in `lib/triage.sh`, after the Task-4 helpers:

```bash
# Assert on the FINAL staged changeset before a fix is committed. Prints a one-word reason
# (artifact|budget|noop) and returns 1 on reject; prints nothing and returns 0 on pass.
# Fail-safe: an unreadable/unmeasurable diff is rejected, not merged.
_triage_quality_gate() {
    local work="$1" repo="$2"
    local max_files="${RALPH_AUTOFIX_MAX_FILES:-25}" max_lines="${RALPH_AUTOFIX_MAX_LINES:-800}"
    [[ "$max_files" =~ ^[0-9]+$ ]] || max_files=25
    [[ "$max_lines" =~ ^[0-9]+$ ]] || max_lines=800
    git -C "$work" add -A >/dev/null 2>&1 || { printf 'noop'; return 1; }
    local numstat
    numstat=$(git -C "$work" diff --cached --numstat HEAD 2>/dev/null) || { printf 'noop'; return 1; }
    [[ -z "$numstat" ]] && { printf 'noop'; return 1; }   # nothing staged -> no-op
    local add del path nonlock_files=0 nonlock_lines=0 sum_changed=0 lock_lines=0
    # numstat lines: "<added>\t<deleted>\t<path>"; binary files use "-" for counts.
    while IFS=$'\t' read -r add del path; do
        [[ -z "$path" ]] && continue
        # R2: artifact path or repo-ignored -> reject immediately
        if _triage_is_artifact_path "$path" || git -C "$work" check-ignore -q "$path" 2>/dev/null; then
            printf 'artifact'; return 1
        fi
        if _triage_is_lockfile "$path"; then
            [[ "$add" =~ ^[0-9]+$ ]] && lock_lines=$((lock_lines + add))
            [[ "$del" =~ ^[0-9]+$ ]] && lock_lines=$((lock_lines + del))
            continue                                   # exempt from the scope budget
        fi
        nonlock_files=$((nonlock_files + 1))
        [[ "$add" =~ ^[0-9]+$ ]] && { nonlock_lines=$((nonlock_lines + add)); sum_changed=$((sum_changed + add)); }
        [[ "$del" =~ ^[0-9]+$ ]] && { nonlock_lines=$((nonlock_lines + del)); sum_changed=$((sum_changed + del)); }
    done <<EOF
$numstat
EOF
    # R1: scope budget on non-lockfile changes
    if [[ "$nonlock_files" -gt "$max_files" || "$nonlock_lines" -gt "$max_lines" ]]; then
        printf 'budget'; return 1
    fi
    # R3: no-op / empty — staged files exist but zero net line change anywhere (source AND lockfile)
    if [[ "$sum_changed" -eq 0 && "$lock_lines" -eq 0 ]]; then
        printf 'noop'; return 1
    fi
    return 0
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `TMPDIR=~/.cache/ralph/tmp bash tests/test_triage.sh 2>&1 | grep -iE 'quality_gate|passes|rejected|reason'`
Expected: PASS on all gate assertions.

- [ ] **Step 5: Commit**

```bash
git add lib/triage.sh tests/test_triage.sh
git commit -m "feat(triage): _triage_quality_gate — reject artifact/over-budget/no-op fixes

Assert on the final staged diff: R2 rejects build-artifact or git-ignored paths;
R1 rejects when non-lockfile changes exceed the file/line budget (lockfiles
exempt); R3 rejects empty/no-op diffs. Fail-safe: unmeasurable -> reject."
```

---

### Task 6: Part C — wire the gate into `_triage_apply_fix`; final suite + PR

**Files:**
- Modify: `lib/triage.sh` (call the gate between the source filter and the push)
- Test: `tests/test_triage.sh`

**Interfaces:**
- Consumes: `_triage_quality_gate` (Task 5), `RALPH_TRIAGE_RC_QUALITY_REJECT` (Task 2), `record_signal`.
- Produces: a rejected fix opens no PR and `_triage_apply_fix` returns `RALPH_TRIAGE_RC_QUALITY_REJECT` (65) — distinct from the provider-failure rc, so a rejected fix does NOT trip the breaker.

- [ ] **Step 1: Write the failing test** — append to `tests/test_triage.sh`. Drive `_triage_apply_fix` with a stub agent that writes a `bin/` artifact, and assert no push + reject rc:

```bash
echo "== quality gate wired into _triage_apply_fix =="
_tt_gate() {
    # agent stub writes a build artifact into the workspace -> gate must reject
    run_ai_tool() { mkdir -p "$PROJECT_DIR/bin/Release" && printf 'junk\n' > "$PROJECT_DIR/bin/Release/x.dll"; return 0; }
    _triage_gh_or_transient() { shift 2; "$@"; }
    _triage_safe_push_branch() { echo "PUSHED" >>"$GATE_LOG"; return 0; }   # must NOT be reached with a push
    gh() { case "$1 $2" in "repo clone") mkdir -p "$3"; ( cd "$3" && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m base ); return 0;; "pr create") echo "PR-CREATED" >>"$GATE_LOG"; return 0;; *) return 0;; esac; }
    _triage_default_branch() { echo main; }
    _triage_apply_fix "o/r" main ralph/fix-ci-9 "prompt" "t" "b" 1 "" "ci:o/r" >/dev/null 2>&1
    echo "rc=$?"
}
GATE_LOG=$(mktemp); export SIGNAL_DIR=$(mktemp -d)
gate_rc=$( _tt_gate 2>/dev/null | sed -n 's/^rc=//p' )
eq "artifact fix returns the quality-reject rc" "65" "$gate_rc"
grep -q 'PR-CREATED' "$GATE_LOG" 2>/dev/null && bad "rejected fix still opened a PR" || ok "rejected fix opened no PR"
grep -rql 'autofix_rejected' "$SIGNAL_DIR" 2>/dev/null && ok "rejected fix records autofix_rejected signal" || bad "no autofix_rejected signal"
# reject rc must be distinct from the breaker's provider-failure rc
[[ "$RALPH_TRIAGE_RC_QUALITY_REJECT" != "$RALPH_TRIAGE_RC_PROVIDER_FAILURE" ]] && ok "reject rc != provider-failure rc (won't trip breaker)" || bad "reject rc collides with provider-failure rc"
rm -f "$GATE_LOG"; rm -rf "$SIGNAL_DIR"; unset SIGNAL_DIR
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `TMPDIR=~/.cache/ralph/tmp bash tests/test_triage.sh 2>&1 | grep -iE 'quality gate wired|reject|FAIL' | head`
Expected: FAIL — the artifact currently gets committed/pushed (gate not wired).

- [ ] **Step 3: Wire the gate** — in `_triage_apply_fix`, insert BETWEEN the no-change check (ends line ~729, the `fi`) and the `local cur; cur=$(...)` push line (~730):

```bash
    local gate_reason=""
    gate_reason=$(_triage_quality_gate "$work" "$repo") || {
        log_warning "[$repo] autofix rejected by quality gate ($gate_reason) — no PR opened."
        declare -F record_signal >/dev/null 2>&1 && \
            record_signal autofix_rejected "Ralph autofix produced a low-quality diff for $repo" "quality gate: $gate_reason" "inspect the rejected diff; tighten the fix prompt or adjust RALPH_AUTOFIX_MAX_FILES/LINES" "triage,autofix" medium "triage" >/dev/null 2>&1 || true
        _triage_apply_fix_return "$RALPH_TRIAGE_RC_QUALITY_REJECT"; return $?
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `TMPDIR=~/.cache/ralph/tmp bash tests/test_triage.sh 2>&1 | grep -iE 'quality gate wired|reject'`
Expected: PASS on all.

- [ ] **Step 5: Run the FULL suite (green gate)**

Run: `TMPDIR=~/.cache/ralph/tmp bash tests/run_all.sh 2>&1 | grep -iE 'FAIL|TOTAL|All suites'`
Expected: every suite `0 failed`, "All suites passed."

- [ ] **Step 6: Commit**

```bash
git add lib/triage.sh tests/test_triage.sh
git commit -m "feat(triage): reject low-quality autofixes before opening a PR

Between the source filter and the push, _triage_apply_fix now runs the quality
gate. A rejected diff opens no PR, records an autofix_rejected signal, and
returns RALPH_TRIAGE_RC_QUALITY_REJECT (65) — distinct from the provider-failure
rc so it never trips the circuit-breaker. Blocks #84-style artifact dumps and
#116-style empty-file no-ops; permits #79/#143-style lockfile fixes."
```

- [ ] **Step 7: Push the branch and open the PR**

```bash
git push -u origin feat/autofix-circuit-breaker-scratch-monitor
gh pr create --repo WomB0ComB0/ralph --base main \
  --title "feat(triage/resources): autofix resilience — scratch monitor, circuit-breaker, quality gate" \
  --body "Implements docs/superpowers/specs/2026-08-03-autofix-circuit-breaker-and-scratch-resource-check-design.md. See the spec for rationale. Follow-up to #69."
```

---

## Self-Review

**Spec coverage:**
- Part A (scratch monitor) → Task 1. ✓ (helper, budget default 90, two warnings, band flips via ok=false)
- Part B (classified rc + breaker) → Tasks 2 (rc + return) & 3 (breaker + signal). ✓
- Part C (quality gate) → Tasks 4 (classifiers), 5 (gate function w/ lockfile exemption R1, artifact R2, no-op R3), 6 (wiring + reject rc + signal + no-PR). ✓
- rc constants distinct (0/1/65/69/75), reject rc doesn't trip breaker → asserted in Task 6 Step 1. ✓
- Verify/memory/resource run after a tripped breaker → the breaker only `break`s the target loop and `return 0`s; downstream patrol phases are separate calls (unchanged). ✓

**Type/name consistency:** `RALPH_TRIAGE_RC_PROVIDER_FAILURE` / `RALPH_TRIAGE_RC_QUALITY_REJECT`, `_triage_is_lockfile`, `_triage_is_artifact_path`, `_triage_quality_gate`, `_triage_map_targets`, `record_signal`, `handle_resource_command`, `_resource_scratch_json` — used consistently across tasks.

**Placeholder scan:** none — every step has concrete code and exact run/expected lines.
