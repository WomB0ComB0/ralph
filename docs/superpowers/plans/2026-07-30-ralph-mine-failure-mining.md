# ralph mine — Failure-Mining Meta-Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `ralph mine` failure-mining meta-loop that reads the durable JSONL run ledger cross-run, ranks recurring failure themes, and (opt-in) feeds them as signals and drafts a dry-run code-fix PR.

**Architecture:** One new bash module `lib/mine.sh` with three escalating, opt-in stages — mine (read-only digest of `.ralph/state/metrics.json`), feed (deduped `ledger_failure` signals via the existing `record_signal`), propose (dry-run `ralph/mine-fix-*` PR via the existing `_triage_apply_fix`). All aggregation is a single tolerant `jq` pass. Wired into `ralph.sh` sourcing, `engine.sh main()` dispatch, and the `review_run` tick.

**Tech Stack:** Bash 3.2+ compatible, `jq`, existing ralph libs (`utils.sh`, `signals.sh`, `triage.sh`, `github.sh`). Tests are scratchpad-style shell harnesses under `tests/`.

## Global Constraints

- Bash must run under `set -euo pipefail` in production (`ralph.sh`); the unit harness runs `set +eu`, so any set-e-only abort needs a native `--test` guard.
- `[[ -z $x ]] && x=$(cmd)` is `set -e`-EXEMPT (AND-OR list) — never use it for a fallible assignment; use `[[ -n $x ]] || x=$(cmd) || { err; }`.
- `mapfile < <(proc-subst)` does not propagate the subshell exit — capture to a var first.
- `local -a x` left empty is unbound under `set -u`; write `local -a x; x=()` on separate statements.
- Commit messages go via `git commit -F <file>` (the pre-bash hook false-blocks inline `-m` messages containing `- ` list lines or flag-like tokens).
- Every write path is opt-in and dry-run-default; nothing pushes to a default branch; source-only filtering is inherited from `_triage_apply_fix`.
- `record_signal` signature (verbatim): `record_signal type observation evidence suggested_action [tags_csv] [severity] [source] [causes_csv]` → echoes the theme_key.
- `_triage_apply_fix` signature (verbatim): `_triage_apply_fix repo base_branch branch prompt title body [apply=0] [filter_context]`.
- Ledger path: `${METRICS_FILE:-${STATE_DIR:-.ralph/state}/metrics.json}`, JSONL, one object per line with fields `timestamp, run_id, iteration, tool, model, latency, tokens, tokens_total, lazy_streak, changed, verify_ok, project_hash`.
- Failure kinds (priority order, first match wins): `stall` (`lazy_streak >= RALPH_MINE_STALL`), `verify_fail` (`verify_ok == false`), `no_progress` (`changed == false`), `token_blowup` (`tokens` > `RALPH_MINE_TOKEN_P` percentile). No `provider_failure` — those iterations never reach `log_metrics`.

---

### Task 1: Module scaffold + `_mine_scan` + `mine_digest` (Stage 1, read-only)

**Files:**
- Create: `lib/mine.sh`
- Modify: `ralph.sh` (add a `source` line after `lib/triage.sh`, around line 43)
- Test: `tests/test_mine.sh`

**Interfaces:**
- Consumes: `command_exists` (utils.sh); env `METRICS_FILE`/`STATE_DIR`, `RALPH_MINE_STALL`, `RALPH_MINE_TOKEN_P`, `RALPH_MINE_TOP`.
- Produces:
  - `_mine_metrics_file()` → prints the ledger path.
  - `_mine_scan([file])` → prints a JSON array of theme objects `{theme,kind,tool,tier,frequency,distinct_runs,first_seen,last_seen,score}` sorted by `score` desc; `[]` when no jq / no file / all-clean.
  - `mine_digest([quiet])` → prints a `mine summary:` line always; full section unless `quiet`; returns 0.

- [ ] **Step 1: Write the failing test** — create `tests/test_mine.sh`:

```bash
#!/bin/bash
# TDD harness for the failure-mining meta-loop (lib/mine.sh).
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export VERBOSE=false
# shellcheck disable=SC1090
source "$R/lib/utils.sh"
source "$R/lib/signals.sh"
source "$R/lib/triage.sh"
source "$R/lib/mine.sh"
set +eu

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (exp [$2] got [$3])"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
LEDGER="$TMP/metrics.json"

# helper: append one ledger row -> row RUN ITER TOOL MODEL LAZY TOKENS CHANGED VERIFY
row() {
  printf '{"timestamp":"2026-07-%02dT10:00:00Z","run_id":"%s","iteration":%s,"tool":"%s","model":"%s","latency":1,"tokens":%s,"tokens_total":%s,"lazy_streak":%s,"changed":%s,"verify_ok":%s,"project_hash":"h"}\n' \
    "$2" "$1" "$3" "$4" "$5" "$7" "$7" "$6" "$8" "$9" >> "$LEDGER"
}

# theme A: verify_fail opencode/opus, 3 iters across 2 runs (opus tier collapse)
row r1 1 opencode claude-opus-4-8 0 100 3 true  false
row r1 2 opencode claude-opus-4-8 0 100 3 true  false
row r2 1 opencode opus            0 100 3 true  false
# theme B: no_progress agy/gemini, 2 iters across 1 run
row r3 1 agy "Gemini 3.5 Flash" 0 100 4 false true
row r3 2 agy "Gemini 3.5 Flash" 0 100 5 false true
# a clean iteration (must be ignored)
row r4 1 opencode opus 0 100 6 true true
# a malformed line (must be tolerated)
printf 'this is not json\n' >> "$LEDGER"

echo "== _mine_scan aggregates + tier-collapse + malformed tolerance =="
scan=$(METRICS_FILE="$LEDGER" _mine_scan)
eq "two themes" "2" "$(printf '%s' "$scan" | jq 'length')"
eq "verify_fail freq/runs, opus tier collapsed" "opus 3 2" \
   "$(printf '%s' "$scan" | jq -r '.[]|select(.kind=="verify_fail")|"\(.tier) \(.frequency) \(.distinct_runs)"')"
eq "top theme is verify_fail (score 6 > 2)" "verify_fail" "$(printf '%s' "$scan" | jq -r '.[0].kind')"

echo "== mine_digest summary line =="
sum=$(METRICS_FILE="$LEDGER" mine_digest quiet)
printf '%s' "$sum" | grep -q '^mine summary: 2 recurring failure themes' && ok "summary counts themes" || bad "summary theme count wrong: $sum"

echo "== empty ledger is a clean no-op =="
eq "empty summary" "mine summary: 0 recurring failure themes, 0 failing iterations (top: none)" \
   "$(METRICS_FILE="$TMP/none.json" mine_digest quiet)"

printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_mine.sh`
Expected: FAIL — `_mine_scan: command not found` (module not yet created).

- [ ] **Step 3: Write minimal implementation** — create `lib/mine.sh`:

```bash
#!/bin/bash
# lib/mine.sh — failure-mining meta-loop over the JSONL run ledger.
# Cross-run analysis of .ralph/state/metrics.json. Read-only by default;
# --feed records deduped signals; --propose drafts a dry-run code-fix PR.
# Depends on: utils.sh, signals.sh (record_signal), triage.sh
# (_triage_apply_fix, _triage_default_branch), github.sh (ralph_gh_current_repo).

# Path to the durable run ledger.
_mine_metrics_file() {
    printf '%s\n' "${METRICS_FILE:-${STATE_DIR:-.ralph/state}/metrics.json}"
}

# Scan the ledger into ranked failure-theme aggregates (JSON array on stdout).
# Tolerant: a corrupt line is skipped, never aborts the pass.
_mine_scan() {
    command_exists jq || { printf '[]\n'; return 0; }
    local file="${1:-}"
    [[ -n "$file" ]] || file="$(_mine_metrics_file)"
    [[ -f "$file" ]] || { printf '[]\n'; return 0; }
    local stall="${RALPH_MINE_STALL:-3}" pctl="${RALPH_MINE_TOKEN_P:-95}"
    [[ "$stall" =~ ^[0-9]+$ ]] || stall=3
    [[ "$pctl"  =~ ^[0-9]+$ ]] || pctl=95
    jq -R -s --argjson stall "$stall" --argjson pctl "$pctl" '
      def tier($m): ($m|ascii_downcase) as $l
        | if   ($l|test("opus"))   then "opus"
          elif ($l|test("sonnet")) then "sonnet"
          elif ($l|test("haiku"))  then "haiku"
          elif ($l|test("gemini")) then "gemini"
          elif ($l|test("gpt|o1|o3")) then "gpt"
          elif ($l|test("grok"))   then "grok"
          elif ($l|test("qwen"))   then "qwen"
          elif ($l|test("llama"))  then "llama"
          elif ($l=="" or $l=="auto") then "auto"
          else ($l|capture("^(?<t>[a-z0-9]+)").t // "other") end;
      [ split("\n")[] | select(length>0) | (try fromjson catch empty)
        | select(type=="object") ] as $rows
      | ($rows | map(.tokens // 0) | sort) as $ts
      | ($ts|length) as $n
      | (if $n==0 then 0 else $ts[ (($n-1) * $pctl / 100) | floor ] end) as $thr
      | [ $rows[] | . as $r
          | ( if   ((($r.lazy_streak)//0) >= $stall) then "stall"
              elif (($r.verify_ok) == false)         then "verify_fail"
              elif (($r.changed) == false)           then "no_progress"
              elif ((($r.tokens)//0) > $thr and $thr > 0) then "token_blowup"
              else null end ) as $k
          | select($k != null)
          | { kind:$k, tool:($r.tool//"?"), tier:tier($r.model//""),
              run:($r.run_id//"?"), ts:($r.timestamp//"") } ]
      | group_by(.kind + ":" + .tool + ":" + .tier)
      | map( { theme:(.[0].kind+":"+.[0].tool+":"+.[0].tier),
               kind:.[0].kind, tool:.[0].tool, tier:.[0].tier,
               frequency: length,
               distinct_runs: ([.[].run]|unique|length),
               first_seen: ([.[].ts]|min),
               last_seen:  ([.[].ts]|max),
               score: (length * ([.[].run]|unique|length)) } )
      | sort_by(-.score)
    ' "$file" 2>/dev/null || printf '[]\n'
}

# Print a one-line summary (+ ranked section unless "quiet").
mine_digest() {
    local mode="${1:-}"
    local top="${RALPH_MINE_TOP:-5}"
    [[ "$top" =~ ^[0-9]+$ ]] || top=5
    local scan nthemes total topline
    scan=$(_mine_scan)
    nthemes=$(printf '%s' "$scan" | jq 'length' 2>/dev/null) || nthemes=0
    [[ "$nthemes" =~ ^[0-9]+$ ]] || nthemes=0
    total=$(printf '%s' "$scan" | jq '[.[].frequency]|add // 0' 2>/dev/null) || total=0
    [[ "$total" =~ ^[0-9]+$ ]] || total=0
    topline=$(printf '%s' "$scan" | jq -r '
      if length==0 then "none"
      else .[0] as $t | "\($t.kind) \($t.tool)/\($t.tier) x\($t.frequency)/\($t.distinct_runs)runs" end' 2>/dev/null) || topline="none"
    [[ -n "$topline" ]] || topline="none"
    printf 'mine summary: %s recurring failure themes, %s failing iterations (top: %s)\n' \
        "$nthemes" "$total" "$topline"
    [[ "$mode" == "quiet" ]] && return 0
    [[ "$nthemes" == "0" ]] && return 0
    printf '%s' "$scan" | jq -r --argjson top "$top" '
      .[:$top][] | "  [\(.kind)] \(.tool)/\(.tier)  x\(.frequency) across \(.distinct_runs) runs  (last \(.last_seen))"
    ' 2>/dev/null || true
    return 0
}
```

Then add the source line to `ralph.sh` immediately after line 43 (`source "$SCRIPT_DIR/lib/triage.sh"`) — mine.sh depends on triage.sh and signals.sh, so it must load after both:

```bash
# shellcheck source=lib/mine.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/mine.sh"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_mine.sh`
Expected: PASS — `TOTAL: N passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
printf 'feat: add ralph mine ledger scan + digest (stage 1)\n\nRead-only cross-run failure-theme aggregation over metrics.json with tier\ncollapse, malformed-line tolerance, and a ranked digest.\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>\n' > /tmp/mine-c1.txt
git add lib/mine.sh ralph.sh tests/test_mine.sh
git commit -F /tmp/mine-c1.txt
```

---

### Task 2: Regression detection

**Files:**
- Modify: `lib/mine.sh` (`_mine_scan` gains `regress` + score multiplier; `mine_digest` shows a marker)
- Test: `tests/test_mine.sh` (add a regression case)

**Interfaces:**
- Consumes: env `RALPH_MINE_WINDOW` (default 50), `RALPH_MINE_BASELINE` (default 200).
- Produces: each theme object also carries `regress` (bool); `score` doubled when `regress`; digest prefixes a marker on regressing themes.

- [ ] **Step 1: Write the failing test** — append to `tests/test_mine.sh` before the TOTAL line:

```bash
echo "== regression: a theme worse in the recent window is flagged =="
REG="$TMP/reg.json"
i=0
while [[ $i -lt 6 ]]; do row rb $i opencode opus 0 100 6 true true;  i=$((i+1)); done  # baseline: clean
while [[ $i -lt 9 ]]; do row rb $i opencode opus 0 100 6 true false; i=$((i+1)); done  # recent: verify_fail
LEDGER_SAVE="$LEDGER"; LEDGER="$REG"   # row() appends to $LEDGER
i=0
while [[ $i -lt 6 ]]; do row rb $i opencode opus 0 100 6 true true;  i=$((i+1)); done
while [[ $i -lt 9 ]]; do row rb $i opencode opus 0 100 6 true false; i=$((i+1)); done
reg=$(METRICS_FILE="$REG" RALPH_MINE_WINDOW=3 RALPH_MINE_BASELINE=6 _mine_scan)
eq "regressing theme flagged" "true" "$(printf '%s' "$reg" | jq -r '.[]|select(.kind=="verify_fail")|.regress')"
LEDGER="$LEDGER_SAVE"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_mine.sh`
Expected: FAIL — `regress` is null (field not yet produced).

- [ ] **Step 3: Write minimal implementation** — replace the whole `jq -R -s ...` invocation in `_mine_scan` with this version (adds per-row index + recent/baseline rate comparison). Insert the two `local` lines just before the `jq` call:

```bash
    local window="${RALPH_MINE_WINDOW:-50}" baseline="${RALPH_MINE_BASELINE:-200}"
    [[ "$window"   =~ ^[0-9]+$ ]] || window=50
    [[ "$baseline" =~ ^[0-9]+$ ]] || baseline=200
    jq -R -s --argjson stall "$stall" --argjson pctl "$pctl" \
             --argjson win "$window" --argjson base "$baseline" '
      def tier($m): ($m|ascii_downcase) as $l
        | if   ($l|test("opus"))   then "opus"
          elif ($l|test("sonnet")) then "sonnet"
          elif ($l|test("haiku"))  then "haiku"
          elif ($l|test("gemini")) then "gemini"
          elif ($l|test("gpt|o1|o3")) then "gpt"
          elif ($l|test("grok"))   then "grok"
          elif ($l|test("qwen"))   then "qwen"
          elif ($l|test("llama"))  then "llama"
          elif ($l=="" or $l=="auto") then "auto"
          else ($l|capture("^(?<t>[a-z0-9]+)").t // "other") end;
      [ split("\n")[] | select(length>0) | (try fromjson catch empty)
        | select(type=="object") ] as $rows
      | ($rows|length) as $N
      | ($rows | map(.tokens // 0) | sort) as $ts
      | ($ts|length) as $n
      | (if $n==0 then 0 else $ts[ (($n-1) * $pctl / 100) | floor ] end) as $thr
      | [ range(0;$N) as $i | $rows[$i] as $r
          | ( if   ((($r.lazy_streak)//0) >= $stall) then "stall"
              elif (($r.verify_ok) == false)         then "verify_fail"
              elif (($r.changed) == false)           then "no_progress"
              elif ((($r.tokens)//0) > $thr and $thr > 0) then "token_blowup"
              else null end ) as $k
          | select($k != null)
          | { kind:$k, tool:($r.tool//"?"), tier:tier($r.model//""),
              run:($r.run_id//"?"), ts:($r.timestamp//""), idx:$i } ]
      | ($N) as $N
      | group_by(.kind + ":" + .tool + ":" + .tier)
      | map( ([.[] | select(.idx >= ($N-$win))] | length) as $recent
           | ([.[] | select(.idx >= ($N-$win-$base) and .idx < ($N-$win))] | length) as $basec
           | ( ($recent / (if $win>0 then $win else 1 end))
               > ($basec / (if $base>0 then $base else 1 end)) and $recent > 0 ) as $reg
           | { theme:(.[0].kind+":"+.[0].tool+":"+.[0].tier),
               kind:.[0].kind, tool:.[0].tool, tier:.[0].tier,
               frequency: length,
               distinct_runs: ([.[].run]|unique|length),
               first_seen: ([.[].ts]|min),
               last_seen:  ([.[].ts]|max),
               regress: $reg,
               score: (length * ([.[].run]|unique|length) * (if $reg then 2 else 1 end)) } )
      | sort_by(-.score)
    ' "$file" 2>/dev/null || printf '[]\n'
```

Then update the ranked-section jq in `mine_digest` to show a marker:

```bash
    printf '%s' "$scan" | jq -r --argjson top "$top" '
      .[:$top][] | (if .regress then "!" else " " end) as $m
      | "\($m) [\(.kind)] \(.tool)/\(.tier)  x\(.frequency) across \(.distinct_runs) runs  (last \(.last_seen))"
    ' 2>/dev/null || true
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_mine.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
printf 'feat: add regression detection to ralph mine scan\n\nEach theme compares recent-window vs baseline failure rate; regressing\nthemes get a score multiplier and a marker in the digest.\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>\n' > /tmp/mine-c2.txt
git add lib/mine.sh tests/test_mine.sh
git commit -F /tmp/mine-c2.txt
```

---

### Task 3: `mine_feed` — deduped `ledger_failure` signals

**Files:**
- Modify: `lib/mine.sh` (add `_mine_action`, `mine_feed`)
- Test: `tests/test_mine.sh` (feed + idempotency + threshold)

**Interfaces:**
- Consumes: `record_signal`, `init_signals` (signals.sh); env `RALPH_MINE_MIN_FREQ` (default 3), `SIGNAL_DIR`, `RUN_ID`.
- Produces: `_mine_action(kind)` → stable hint string. `mine_feed()` → records one deduped signal per theme with `frequency >= RALPH_MINE_MIN_FREQ` AND `distinct_runs >= 2`; prints `mine: fed N signal(s)`; returns 0. Signal `type=ledger_failure`, stable `evidence="ledger failure theme <theme>"` so re-runs upsert (idempotent).

- [ ] **Step 1: Write the failing test** — append before the TOTAL line:

```bash
echo "== mine_feed records deduped signals, idempotent, threshold-gated =="
export SIGNAL_DIR="$TMP/sig" RUN_ID="r-feed"; init_signals
fed=$(METRICS_FILE="$LEDGER" RALPH_MINE_MIN_FREQ=3 mine_feed)
printf '%s' "$fed" | grep -q 'mine: fed 1 signal' && ok "fed exactly the qualifying theme" || bad "feed count wrong: $fed"
n1=$(find "$SIGNAL_DIR" -name '*.json' -not -path '*/.archive/*' | wc -l | tr -d ' ')
METRICS_FILE="$LEDGER" RALPH_MINE_MIN_FREQ=3 mine_feed >/dev/null   # feed again -> upsert
n2=$(find "$SIGNAL_DIR" -name '*.json' -not -path '*/.archive/*' | wc -l | tr -d ' ')
eq "feed is idempotent (no new signal file)" "$n1" "$n2"
grep -rl 'no_progress' "$SIGNAL_DIR" >/dev/null 2>&1 && bad "single-run theme leaked into signals" || ok "single-run theme not fed"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_mine.sh`
Expected: FAIL — `mine_feed: command not found`.

- [ ] **Step 3: Write minimal implementation** — add to `lib/mine.sh`:

```bash
# Suggested-action hint per failure kind (stable, human-actionable).
_mine_action() {
    case "$1" in
        stall)        printf 'sustained no-progress; check the stall guard, instructions, or intervene\n' ;;
        verify_fail)  printf 'agent completes but verification fails; inspect the verify/build gate for this tool\n' ;;
        no_progress)  printf 'iterations make no file changes; prompt/model may be stuck — check instructions or switch model\n' ;;
        token_blowup) printf 'iteration token cost anomaly; check prompt bloat or oversized artifacts\n' ;;
        *)            printf 'investigate recurring failure\n' ;;
    esac
}

# Record deduped ledger_failure signals for qualifying themes.
mine_feed() {
    command_exists jq || { printf 'mine: fed 0 signal(s) (jq unavailable)\n'; return 0; }
    local min="${RALPH_MINE_MIN_FREQ:-3}"
    [[ "$min" =~ ^[0-9]+$ ]] || min=3
    declare -F init_signals >/dev/null && init_signals
    local scan qualifying fed=0
    scan=$(_mine_scan)
    qualifying=$(printf '%s' "$scan" | jq -r --argjson min "$min" '
      .[] | select(.frequency >= $min and .distinct_runs >= 2)
      | [.theme, .kind, .tool, .tier, (.frequency|tostring), (.distinct_runs|tostring), (.regress|tostring)]
      | @tsv' 2>/dev/null)
    local theme kind tool tier freq runs reg
    while IFS=$'\t' read -r theme kind tool tier freq runs reg; do
        [[ -n "$theme" ]] || continue
        local sev="medium"
        [[ "$kind" == "no_progress" || "$kind" == "token_blowup" ]] && sev="low"
        [[ "$reg" == "true" ]] && sev="high"
        record_signal ledger_failure \
            "Recurring $kind failures on $tool/$tier ($freq iters, $runs runs)" \
            "ledger failure theme $theme" \
            "$(_mine_action "$kind")" \
            "mined,$kind" "$sev" "mine" >/dev/null 2>&1 || true
        fed=$((fed+1))
    done <<< "$qualifying"
    printf 'mine: fed %s signal(s)\n' "$fed"
    return 0
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_mine.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
printf 'feat: add ralph mine --feed signal integration\n\nRecords deduped ledger_failure signals for themes recurring across >=2\nruns, feeding the existing signal->skill->recall pipeline. Idempotent.\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>\n' > /tmp/mine-c3.txt
git add lib/mine.sh tests/test_mine.sh
git commit -F /tmp/mine-c3.txt
```

---

### Task 4: `mine_propose` — dry-run code-fix PR via triage engine

**Files:**
- Modify: `lib/mine.sh` (add `mine_propose`)
- Test: `tests/test_mine.sh` (dry-run does no clone/push; non-repo skip)

**Interfaces:**
- Consumes: `ralph_gh_current_repo` (github.sh), `_triage_default_branch` + `_triage_apply_fix` (triage.sh), `_signal_sha1` (signals.sh), `log_info` (utils.sh).
- Produces: `mine_propose([apply])` — takes the top scanned theme; resolves the current GitHub slug; on success calls `_triage_apply_fix repo default ralph/mine-fix-<hash> "$prompt" "$title" "$body" "$apply" "mine:<kind>"`. `apply` empty/0 = dry-run. Returns 0 with a clean skip when there is no top theme or the project is not a GitHub repo.

- [ ] **Step 1: Write the failing test** — append before the TOTAL line:

```bash
echo "== mine_propose dry-run does no clone/push; non-repo skips cleanly =="
BIN="$TMP/bin"; mkdir -p "$BIN"; GHLOG="$TMP/gh.log"; : > "$GHLOG"
cat > "$BIN/gh" <<EOF
#!/bin/bash
echo "gh \$*" >> "$GHLOG"
case "\$*" in
  *"repo view"*"nameWithOwner"*)     echo "acme/widget" ;;
  *"repo view"*"defaultBranchRef"*)  echo "main" ;;
  *clone*)                           echo "CLONE-CALLED" >> "$GHLOG" ;;
esac
EOF
chmod +x "$BIN/gh"
out=$(PATH="$BIN:$PATH" METRICS_FILE="$LEDGER" mine_propose 2>&1)
printf '%s' "$out" | grep -qi 'DRY-RUN' && ok "propose prints a dry-run plan" || bad "no dry-run plan: $out"
grep -q 'CLONE-CALLED' "$GHLOG" 2>/dev/null && bad "dry-run cloned the repo" || ok "dry-run performed no clone"

echo "== non-GitHub project: clean skip, exit 0 =="
cat > "$BIN/gh" <<'EOF'
#!/bin/bash
echo "not a gh repo" >&2; exit 1
EOF
chmod +x "$BIN/gh"
PATH="$BIN:$PATH" METRICS_FILE="$LEDGER" mine_propose >/dev/null 2>&1
eq "propose returns 0 when not a GitHub repo" "0" "$?"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_mine.sh`
Expected: FAIL — `mine_propose: command not found`.

- [ ] **Step 3: Write minimal implementation** — add to `lib/mine.sh`:

```bash
# Draft a code-fix for the single top recurring theme. Dry-run unless apply=1.
mine_propose() {
    local apply="${1:-0}"
    [[ "$apply" == "1" ]] || apply=0
    command_exists jq || { log_info "mine: jq unavailable; cannot propose."; return 0; }
    local scan top kind tool tier freq runs
    scan=$(_mine_scan)
    top=$(printf '%s' "$scan" | jq -r '.[0] // empty' 2>/dev/null)
    if [[ -z "$top" ]]; then
        log_info "mine: no recurring failure theme to propose a fix for."
        return 0
    fi
    kind=$(printf '%s' "$top" | jq -r '.kind')
    tool=$(printf '%s' "$top" | jq -r '.tool')
    tier=$(printf '%s' "$top" | jq -r '.tier')
    freq=$(printf '%s' "$top" | jq -r '.frequency')
    runs=$(printf '%s' "$top" | jq -r '.distinct_runs')

    local repo=""
    if declare -F ralph_gh_current_repo >/dev/null; then
        repo=$(ralph_gh_current_repo 2>/dev/null) || repo=""
    fi
    if [[ -z "$repo" || "$repo" != */* ]]; then
        log_info "mine: current project is not a GitHub repo; skipping fix proposal (mine/--feed still work)."
        return 0
    fi

    local base hash branch title body prompt
    base=$(_triage_default_branch "$repo" 2>/dev/null) || base=""
    [[ -n "$base" ]] || base="main"
    hash=$(printf '%s' "$top" | jq -r '.theme' | _signal_sha1 2>/dev/null | cut -c1-8)
    [[ -n "$hash" ]] || hash="theme"
    branch="ralph/mine-fix-$hash"
    title="mine: address recurring $kind failures ($tool/$tier)"
    body="Ralph's failure-mining meta-loop found a recurring $kind failure pattern on $tool/$tier: $freq failing iterations across $runs runs. $(_mine_action "$kind")"
    prompt="You are addressing a recurring failure the ralph loop mined from its run ledger.
Failure kind: $kind (tool $tool, model tier $tier), $freq occurrences across $runs runs.
Guidance: $(_mine_action "$kind")
Make the smallest, safest source change that reduces this failure. Do not touch CI, secrets, or unrelated code. If no code change is warranted, make no changes."

    _triage_apply_fix "$repo" "$base" "$branch" "$prompt" "$title" "$body" "$apply" "mine:$kind"
    return 0
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_mine.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
printf 'feat: add ralph mine --propose dry-run fix PR\n\nDrafts a source-only code-fix PR for the top recurring theme via the\ntriage engine. Dry-run default, never pushes default, guards non-GitHub\nprojects with a clean skip.\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>\n' > /tmp/mine-c4.txt
git add lib/mine.sh tests/test_mine.sh
git commit -F /tmp/mine-c4.txt
```

---

### Task 5: CLI dispatch + `review_run` one-liner + suite registration

**Files:**
- Modify: `lib/mine.sh` (add `handle_mine_command`)
- Modify: `lib/engine.sh` (dispatch in `main()` after the `triage` block ~line 2194; one-liner in `review_run` after the lint block ~line 3660)
- Modify: `tests/run_all.sh` (register `test_mine.sh` after the lint line ~41)
- Test: `tests/test_mine.sh` (arg parsing) + end-to-end `ralph.sh mine`

**Interfaces:**
- Consumes: `mine_digest`, `mine_feed`, `mine_propose`.
- Produces: `handle_mine_command "$@"` — parses `--feed`, `--propose`, `--apply` (composable, `--apply` implies `--propose`); always prints the digest; then feed and/or propose as requested. `ralph mine` runs read-only.

- [ ] **Step 1: Write the failing test** — append before the TOTAL line:

```bash
echo "== handle_mine_command arg parsing =="
o=$(METRICS_FILE="$LEDGER" handle_mine_command 2>&1)
printf '%s' "$o" | grep -q '^mine summary:' && ok "bare mine prints digest" || bad "no digest: $o"
o=$(METRICS_FILE="$LEDGER" SIGNAL_DIR="$TMP/sig2" RUN_ID=r-cli handle_mine_command --feed 2>&1)
printf '%s' "$o" | grep -q 'mine: fed' && ok "--feed runs feed" || bad "--feed did not feed: $o"

echo "== end-to-end via ralph.sh =="
e=$(cd "$R" && METRICS_FILE="$LEDGER" ./ralph.sh mine 2>&1)
printf '%s' "$e" | grep -q '^mine summary:' && ok "ralph.sh mine dispatches" || bad "ralph.sh mine failed: $e"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_mine.sh`
Expected: FAIL — `handle_mine_command: command not found` and `ralph.sh mine` unrecognized.

- [ ] **Step 3: Write minimal implementation.**

Add to `lib/mine.sh`:

```bash
# CLI entrypoint: ralph mine [--feed] [--propose] [--apply]
handle_mine_command() {
    local do_feed=0 do_propose=0 apply=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --feed)    do_feed=1 ;;
            --propose) do_propose=1 ;;
            --apply)   apply=1; do_propose=1 ;;
            -h|--help)
                printf 'usage: ralph mine [--feed] [--propose] [--apply]\n'
                printf '  (default)   read-only ranked failure-theme digest\n'
                printf '  --feed      also record deduped ledger_failure signals\n'
                printf '  --propose   also draft a dry-run code-fix PR for the top theme\n'
                printf '  --apply     with --propose, actually open the PR (never pushes default)\n'
                return 0 ;;
            *) log_warning "mine: ignoring unknown argument: $1" ;;
        esac
        shift
    done
    mine_digest
    [[ "$do_feed" == "1" ]] && mine_feed
    [[ "$do_propose" == "1" ]] && mine_propose "$apply"
    return 0
}
```

Add the dispatch block to `lib/engine.sh` `main()` immediately after the `triage` block (after line 2194, before the `resource` block at 2195):

```bash
    if [[ "${1:-}" == "mine" ]]; then
        shift
        handle_mine_command "$@"
        exit $?
    fi
```

Add the one-liner to `lib/engine.sh` `review_run`, immediately after the lint block (after line 3660):

```bash
    if declare -F mine_digest >/dev/null; then
        log_info "$(mine_digest quiet)"
    fi
```

Register the suite in `tests/run_all.sh` immediately after the lint line (line 41):

```bash
run mine     "$DIR/test_mine.sh"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_mine.sh && bash tests/run_all.sh`
Expected: PASS for `test_mine.sh`; `run_all.sh` includes `mine` and stays green.

- [ ] **Step 5: Commit**

```bash
printf 'feat: wire ralph mine CLI, review tick, and test suite\n\nAdds handle_mine_command dispatch in main(), a mine one-liner on the\n--review tick, and registers test_mine.sh in run_all.sh.\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>\n' > /tmp/mine-c5.txt
git add lib/mine.sh lib/engine.sh tests/run_all.sh tests/test_mine.sh
git commit -F /tmp/mine-c5.txt
```

---

### Task 6: Native `--test` smoke, README, shellcheck, full-suite green

**Files:**
- Modify: the native `--test` registry (locate with the grep in Step 1 — the same place the existing lint/signals set-e smokes live)
- Modify: `README.md` (document `ralph mine` + `RALPH_MINE_*`)
- Test: full `tests/run_all.sh` + `./ralph.sh --test`

**Interfaces:**
- Consumes: everything above.
- Produces: a native smoke that runs `mine_digest quiet` under `set -e`/`set -u` against an empty ledger and asserts a clean `mine summary: 0` line + exit 0 (catches set-e-only aborts the `set +eu` unit harness misses).

- [ ] **Step 1: Locate the native test registry.**

Run: `grep -n "run_internal_tests\|_native_\|--test)" lib/engine.sh tests/run_internal_tests.sh | head`
Expected: identifies the function/helpers that native `--test` uses for its set-e smokes (e.g. the pass/fail helper names). Use those exact helper names in Step 2.

- [ ] **Step 2: Write the smoke** — add, alongside the existing native smokes, an assertion (substitute the confirmed helper names for `_native_ok`/`_native_bad`):

```bash
# mine: digest must not abort under set -e/-u on an empty ledger
if ( set -euo pipefail
     METRICS_FILE="$(mktemp -u)" mine_digest quiet | grep -q '^mine summary: 0 recurring' ); then
    _native_ok "mine digest clean on empty ledger"
else
    _native_bad "mine digest aborted or wrong under set -e"
fi
```

- [ ] **Step 3: Run to verify it passes.**

Run: `./ralph.sh --test 2>&1 | grep -i mine`
Expected: PASS line for "mine digest clean on empty ledger" (mine.sh is sourced by ralph.sh, so the function is available on the `--test` path).

- [ ] **Step 4: Document in `README.md`.** Add a `ralph mine` entry to the CLI/subcommand list and a knobs block:

```markdown
### `ralph mine` — failure-mining meta-loop

Analyzes the cross-run JSONL ledger (`.ralph/state/metrics.json`) for recurring
failure themes (stall / verify_fail / no_progress / token_blowup).

- `ralph mine` — read-only ranked digest.
- `ralph mine --feed` — also record deduped `ledger_failure` signals (themes recurring across >=2 runs).
- `ralph mine --propose` — also draft a dry-run source-only fix PR for the top theme.
- `ralph mine --propose --apply` — open the `ralph/mine-fix-*` PR (never pushes the default branch).

Knobs: `RALPH_MINE_MIN_FREQ` (3), `RALPH_MINE_WINDOW` (50), `RALPH_MINE_BASELINE` (200),
`RALPH_MINE_TOP` (5), `RALPH_MINE_STALL` (3), `RALPH_MINE_TOKEN_P` (95).
```

- [ ] **Step 5: Shellcheck + full suite, then commit.**

```bash
shellcheck -x lib/mine.sh || true
bash tests/run_all.sh
./ralph.sh --test
printf 'test: native mine smoke + README docs for ralph mine\n\nAdds a set-e native smoke for mine_digest and documents the mine\nsubcommand and RALPH_MINE_* knobs.\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>\n' > /tmp/mine-c6.txt
git add lib/engine.sh README.md
git commit -F /tmp/mine-c6.txt
```

Expected: `run_all.sh` all suites green (incl. `mine`); `./ralph.sh --test` green with the mine smoke; shellcheck clean on `lib/mine.sh`.

---

## Self-Review

**Spec coverage:**
- Stage 1 mine (read-only digest) → Task 1 (+ regression Task 2). Covered.
- Stage 2 feed (deduped `ledger_failure` signals, >=2-run gate, idempotent) → Task 3. Covered.
- Stage 3 propose (dry-run `_triage_apply_fix`, repo-slug guard, self-target via triage's existing strip) → Task 4. Covered.
- CLI `ralph mine [--feed|--propose|--apply]` + `review_run` one-liner → Task 5. Covered.
- Failure taxonomy (stall/verify_fail/no_progress/token_blowup; no provider_failure) → Task 1 jq. Covered.
- Theme key `<kind>:<tool>:<model-tier>` with tier collapse → Task 1 `tier()`. Covered.
- Ranking freq × cross-run spread × regression multiplier → Tasks 1–2. Covered.
- Knobs `RALPH_MINE_*` → Tasks 1–3, documented Task 6. Covered.
- Tests: the 8 spec assertions map to Tasks 1–5 test steps; native smoke Task 6. Covered.
- README + native `--test` → Task 6. Covered.

**Placeholder scan:** none — every code/test step has complete code. Task 6 Step 1 is a deliberate locate-step (grep) because the native registry helper names must be confirmed in-repo before the Step 2 edit; Step 2 notes to substitute the confirmed names.

**Type consistency:** `_mine_scan` produces `{theme,kind,tool,tier,frequency,distinct_runs,first_seen,last_seen,regress,score}`; `mine_digest`, `mine_feed`, `mine_propose` all read those exact keys. `record_signal`/`_triage_apply_fix` calls match their verbatim signatures in Global Constraints. `ralph_gh_current_repo`, `_triage_default_branch`, `_signal_sha1`, `log_info`, `log_warning`, `command_exists` are existing in-repo symbols.
