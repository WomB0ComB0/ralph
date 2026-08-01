#!/bin/bash
# TDD harness for the ralph memory → Synapse bridge (lib/memory.sh).
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export VERBOSE=false
# shellcheck disable=SC1090
source "$R/lib/utils.sh"
source "$R/lib/signals.sh"
source "$R/lib/skills.sh"
source "$R/lib/github.sh"
source "$R/lib/triage.sh"
source "$R/lib/mine.sh"
source "$R/lib/synapse.sh"
source "$R/lib/memory.sh"
set +eu

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (exp [$2] got [$3])"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "== memory_ground wraps synapse_ground and is fail-open =="
synapse_ground() { printf '<synapse_context>\n- (ralph://skill/x) lesson\n</synapse_context>\n'; }
out=$(memory_ground "some query"); rc=$?
eq "ground returns 0" "0" "$rc"
printf '%s' "$out" | grep -q '<synapse_context>' && ok "ground emits context block" || bad "no block: $out"
synapse_ground() { return 7; }
out=$(memory_ground "q"); rc=$?
eq "ground fail-open rc 0" "0" "$rc"
eq "ground fail-open empty" "" "$out"

echo "== memory_sync: verified-only skills, theme gate, tally, idempotency =="
SKILL_DIR="$TMP/skills"; SIGNAL_DIR="$TMP/sig"; mkdir -p "$SKILL_DIR" "$SIGNAL_DIR"
printf '{"theme_key":"typefix","problem":"TS2345 arg type","resolution":"add annotation","verified":true}\n'  >"$SKILL_DIR/typefix.json"
printf '{"theme_key":"draft","problem":"x","resolution":"y","verified":false}\n' >"$SKILL_DIR/draft.json"
LEDGER="$TMP/metrics.json"
for i in 1 2; do printf '{"run_id":"r1","iteration":%s,"tool":"opencode","model":"opus","tokens":10,"lazy_streak":3,"changed":true,"verify_ok":false}\n' "$i" >>"$LEDGER"; done
printf '{"run_id":"r2","iteration":1,"tool":"opencode","model":"opus","tokens":10,"lazy_streak":3,"changed":true,"verify_ok":false}\n' >>"$LEDGER"

synapse_ping() { return 0; }
SEEN="$TMP/seen"; : >"$SEEN"
_synapse_ingest_doc() {
  local id; id=$(printf '%s' "$1" | jq -r '.doc_id')
  printf '%s\n' "$1" >>"$TMP/docs.log"
  if grep -qx "$id" "$SEEN" 2>/dev/null; then printf '{"status":"replayed","doc_id":"%s"}' "$id"
  else printf '%s\n' "$id" >>"$SEEN"; printf '{"status":"ingested","doc_id":"%s"}' "$id"; fi
}

out=$(SKILL_DIR="$SKILL_DIR" SIGNAL_DIR="$SIGNAL_DIR" METRICS_FILE="$LEDGER" memory_sync); rc=$?
eq "sync returns 0" "0" "$rc"
eq "one skill + one theme ingested (2)" "2" "$(printf '%s' "$out" | sed -n 's/.*synced \([0-9]*\).*/\1/p')"
printf '%s' "$out" | grep -q '2 ingested' && ok "tally: 2 ingested" || bad "tally wrong: $out"
grep -q '"draft"' "$TMP/docs.log" 2>/dev/null && bad "unverified skill leaked" || ok "verified-only filter holds"
out2=$(SKILL_DIR="$SKILL_DIR" SIGNAL_DIR="$SIGNAL_DIR" METRICS_FILE="$LEDGER" memory_sync)
printf '%s' "$out2" | grep -q '0 ingested, 2 replayed' && ok "idempotent re-sync: all replayed" || bad "not idempotent: $out2"

echo "== memory_sync: theme below gate is skipped =="
LOW="$TMP/low.json"
printf '{"run_id":"r9","iteration":1,"tool":"agy","model":"gemini","tokens":10,"lazy_streak":3,"changed":true,"verify_ok":false}\n' >"$LOW"
: >"$TMP/docs2.log"
_synapse_ingest_doc() { printf '%s\n' "$1" >>"$TMP/docs2.log"; printf '{"status":"ingested"}'; }
mkdir -p "$TMP/empty"
SKILL_DIR="$TMP/empty" SIGNAL_DIR="$SIGNAL_DIR" METRICS_FILE="$LOW" memory_sync >/dev/null
[[ -s "$TMP/docs2.log" ]] && bad "below-gate theme was ingested" || ok "theme gate holds (freq<3)"

echo "== memory_sync: fail-open + records memory_sync_failed =="
synapse_ping() { return 0; }
_synapse_ingest_doc() { return 42; }
rc=0; out=$(SKILL_DIR="$SKILL_DIR" SIGNAL_DIR="$SIGNAL_DIR" METRICS_FILE="$LEDGER" memory_sync) || rc=$?
eq "sync fail-open rc 0" "0" "$rc"
printf '%s' "$out" | grep -q 'failed' && ok "tally reports failures" || bad "no failure tally: $out"
ls "$SIGNAL_DIR"/*.json >/dev/null 2>&1 && ok "memory_sync_failed signal recorded" || bad "no failure signal recorded"

echo "== memory_sync: unreachable Synapse is a clean no-op =="
synapse_ping() { return 1; }
out=$(SKILL_DIR="$SKILL_DIR" SIGNAL_DIR="$TMP/sig3" METRICS_FILE="$LEDGER" memory_sync); rc=$?
eq "unreachable rc 0" "0" "$rc"
printf '%s' "$out" | grep -q 'synced 0' && ok "no-op when Synapse down" || bad "not a no-op: $out"

printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
