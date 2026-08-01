#!/bin/bash
# TDD harness for the failure-mining meta-loop (lib/mine.sh).
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export VERBOSE=false
# shellcheck disable=SC1090
source "$R/lib/utils.sh"
source "$R/lib/signals.sh"
source "$R/lib/github.sh"
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
    "$2" "$1" "$2" "$3" "$4" "$6" "$6" "$5" "$8" "$9" >> "$LEDGER"
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

echo "== regression: a theme worse in the recent window is flagged =="
REG="$TMP/reg.json"
LEDGER_SAVE="$LEDGER"; LEDGER="$REG"   # row() appends to $LEDGER
i=0
while [[ $i -lt 6 ]]; do row rb $i opencode opus 0 100 6 true true;  i=$((i+1)); done  # baseline: clean
while [[ $i -lt 9 ]]; do row rb $i opencode opus 0 100 6 true false; i=$((i+1)); done  # recent: verify_fail
reg=$(METRICS_FILE="$REG" RALPH_MINE_WINDOW=3 RALPH_MINE_BASELINE=6 _mine_scan)
eq "regressing theme flagged" "true" "$(printf '%s' "$reg" | jq -r '.[]|select(.kind=="verify_fail")|.regress')"
LEDGER="$LEDGER_SAVE"

echo "== mine_feed records deduped signals, idempotent, threshold-gated =="
export SIGNAL_DIR="$TMP/sig" RUN_ID="r-feed"; init_signals
fed=$(METRICS_FILE="$LEDGER" RALPH_MINE_MIN_FREQ=3 mine_feed)
printf '%s' "$fed" | grep -q 'mine: fed 1 signal' && ok "fed exactly the qualifying theme" || bad "feed count wrong: $fed"
n1=$(find "$SIGNAL_DIR" -name '*.json' -not -path '*/.archive/*' | wc -l | tr -d ' ')
METRICS_FILE="$LEDGER" RALPH_MINE_MIN_FREQ=3 mine_feed >/dev/null   # feed again -> upsert
n2=$(find "$SIGNAL_DIR" -name '*.json' -not -path '*/.archive/*' | wc -l | tr -d ' ')
eq "feed is idempotent (no new signal file)" "$n1" "$n2"
grep -rl 'no_progress' "$SIGNAL_DIR" >/dev/null 2>&1 && bad "single-run theme leaked into signals" || ok "single-run theme not fed"

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

echo "== handle_mine_command arg parsing =="
o=$(METRICS_FILE="$LEDGER" handle_mine_command 2>&1)
printf '%s' "$o" | grep -q '^mine summary:' && ok "bare mine prints digest" || bad "no digest: $o"
o=$(METRICS_FILE="$LEDGER" SIGNAL_DIR="$TMP/sig2" RUN_ID=r-cli handle_mine_command --feed 2>&1)
printf '%s' "$o" | grep -q 'mine: fed' && ok "--feed runs feed" || bad "--feed did not feed: $o"

echo "== end-to-end via ralph.sh =="
e=$(cd "$R" && METRICS_FILE="$LEDGER" ./ralph.sh mine 2>&1)
printf '%s' "$e" | grep -q '^mine summary:' && ok "ralph.sh mine dispatches" || bad "ralph.sh mine failed: $e"

echo "== RALPH_MINE_MAX_LINES bounds the ledger read to the last N iterations =="
BND="$TMP/bnd.json"
LSAVE="$LEDGER"; LEDGER="$BND"
row ro 1 opencode opus 0 100 0 true false   # old verify_fail theme (run ro)
row ro 2 opencode opus 0 100 0 true false
row rp 1 opencode opus 0 100 0 true false   # (run rp) -> theme spans 2 runs
row rp 2 opencode opus 0 100 0 true false
row rq 1 agy gemini 0 100 0 false true       # recent no_progress theme (run rq)
row rq 2 agy gemini 0 100 0 false true
LEDGER="$LSAVE"
bnd=$(METRICS_FILE="$BND" RALPH_MINE_MAX_LINES=2 _mine_scan)
eq "bound=2 scans only the last 2 lines -> 1 theme" "1" "$(printf '%s' "$bnd" | jq 'length')"
eq "bounded theme is the recent no_progress" "no_progress" "$(printf '%s' "$bnd" | jq -r '.[0].kind')"
unb=$(METRICS_FILE="$BND" _mine_scan)
eq "default (unbounded window) sees both themes" "2" "$(printf '%s' "$unb" | jq 'length')"

printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
