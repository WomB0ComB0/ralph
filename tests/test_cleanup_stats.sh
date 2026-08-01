#!/bin/bash
# TDD harness for read-only cleanup-latency aggregation (ralph-qbt).
# Sources the libs directly; needs only jq. Covers valid aggregation, malformed
# artifacts, empty input, retention boundaries, percentile edges, kind separation,
# redaction, and symlink safety.
# Usage: bash test_cleanup_stats.sh

RALPH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "$RALPH_ROOT/lib/utils.sh"
# shellcheck disable=SC1090
source "$RALPH_ROOT/lib/processes.sh"

PASS=0
FAIL=0
note() { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }

if ! command -v jq >/dev/null 2>&1; then
    note "jq unavailable; cleanup-stats requires jq"
    printf '\n== TOTAL: 0 passed, 1 failed ==\n'
    exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Write stdin to <dir>/process-cleanup.json.
write_artifact() { local dir="$1"; mkdir -p "$dir"; cat > "$dir/process-cleanup.json"; }
# Field extractor over a captured JSON string.
f() { jq -r "$2" <<<"$1"; }

# ---------------------------------------------------------------------------
note "== valid aggregation + kind separation + rates =="
ROOT="$TMP/valid"
write_artifact "$ROOT/run-a" <<'J'
{"schema_version":1,"artifact":"ralph_process_cleanup","events":[
 {"kind":"provider","trigger":"timeout","outcome":"term","duration_ms":100,"finished_at":"2026-07-14T00:00:00Z"},
 {"kind":"provider","trigger":"exit","outcome":"already_exited","duration_ms":200,"finished_at":"2026-07-14T00:00:01Z"},
 {"kind":"provider","trigger":"signal","outcome":"kill","duration_ms":300,"finished_at":"2026-07-14T00:00:02Z"},
 {"kind":"live_smoke","trigger":"normal","outcome":"already_exited","duration_ms":5,"finished_at":"2026-07-14T00:00:03Z"}]}
J
write_artifact "$ROOT/run-b" <<'J'
{"schema_version":1,"artifact":"ralph_process_cleanup","events":[
 {"kind":"provider","trigger":"quiescence","outcome":"term","duration_ms":400,"finished_at":"2026-07-14T00:00:04Z"},
 {"kind":"live_smoke","trigger":"verification","outcome":"term","duration_ms":15,"finished_at":"2026-07-14T00:00:05Z"}]}
J
OUT=$(handle_cleanup_stats_command "$ROOT"); rc=$?
assert_eq "returns 0" 0 "$rc"
jq -e . <<<"$OUT" >/dev/null 2>&1 && ok "emits valid JSON" || bad "output is not valid JSON"
assert_eq "artifact label" "ralph_cleanup_stats" "$(f "$OUT" .artifact)"
assert_eq "schema_version" "1" "$(f "$OUT" .schema_version)"
assert_eq "percentile method documented" "nearest-rank" "$(f "$OUT" .percentile_method)"
assert_eq "runs_scanned" "2" "$(f "$OUT" .runs_scanned)"
assert_eq "artifacts_skipped" "0" "$(f "$OUT" .artifacts_skipped)"
# provider: durations [100,200,300,400] -> p50 rank ceil(2.0)=2 -> 200; p95 rank ceil(3.8)=4 -> 400
assert_eq "provider sample_count" "4" "$(f "$OUT" .kinds.provider.sample_count)"
assert_eq "provider p50" "200" "$(f "$OUT" .kinds.provider.p50_duration_ms)"
assert_eq "provider p95" "400" "$(f "$OUT" .kinds.provider.p95_duration_ms)"
assert_eq "provider max" "400" "$(f "$OUT" .kinds.provider.max_duration_ms)"
assert_eq "provider term_count" "2" "$(f "$OUT" .kinds.provider.term_count)"
assert_eq "provider kill_count" "1" "$(f "$OUT" .kinds.provider.kill_count)"
assert_eq "provider term_rate" "0.5" "$(f "$OUT" .kinds.provider.term_rate)"
assert_eq "provider kill_rate" "0.25" "$(f "$OUT" .kinds.provider.kill_rate)"
# kind separation: live_smoke events must NOT bleed into provider (and vice versa)
assert_eq "live_smoke sample_count" "2" "$(f "$OUT" .kinds.live_smoke.sample_count)"
assert_eq "live_smoke max" "15" "$(f "$OUT" .kinds.live_smoke.max_duration_ms)"
assert_eq "live_smoke term_rate" "0.5" "$(f "$OUT" .kinds.live_smoke.term_rate)"

# ---------------------------------------------------------------------------
note "== malformed / invalid artifacts are skipped, not fatal =="
ROOT="$TMP/malformed"
write_artifact "$ROOT/ok" <<'J'
{"schema_version":1,"artifact":"ralph_process_cleanup","events":[
 {"kind":"provider","trigger":"normal","outcome":"term","duration_ms":50,"finished_at":"2026-07-14T00:00:00Z"}]}
J
write_artifact "$ROOT/not-json" <<'J'
{ this is not valid json
J
write_artifact "$ROOT/wrong-schema" <<'J'
{"schema_version":2,"artifact":"ralph_process_cleanup","events":[]}
J
write_artifact "$ROOT/wrong-artifact" <<'J'
{"schema_version":1,"artifact":"something_else","events":[]}
J
write_artifact "$ROOT/events-not-array" <<'J'
{"schema_version":1,"artifact":"ralph_process_cleanup","events":{}}
J
mkdir -p "$ROOT/no-artifact"   # a run dir with no cleanup file at all
OUT=$(handle_cleanup_stats_command "$ROOT"); rc=$?
assert_eq "malformed set returns 0" 0 "$rc"
assert_eq "only the valid artifact is scanned" "1" "$(f "$OUT" .runs_scanned)"
assert_eq "four malformed artifacts skipped" "4" "$(f "$OUT" .artifacts_skipped)"
assert_eq "valid artifact still aggregated" "1" "$(f "$OUT" .kinds.provider.sample_count)"
# Events that fail the per-event allowlist inside an otherwise-valid file are dropped.
write_artifact "$ROOT/dirty-events" <<'J'
{"schema_version":1,"artifact":"ralph_process_cleanup","events":[
 {"kind":"provider","trigger":"normal","outcome":"term","duration_ms":60,"finished_at":"2026-07-14T00:00:00Z"},
 {"kind":"provider","trigger":"bogus","outcome":"term","duration_ms":70,"finished_at":"2026-07-14T00:00:00Z"},
 {"kind":"other","trigger":"normal","outcome":"term","duration_ms":80,"finished_at":"2026-07-14T00:00:00Z"},
 {"kind":"provider","trigger":"normal","outcome":"term","duration_ms":-5,"finished_at":"2026-07-14T00:00:00Z"},
 {"kind":"provider","trigger":"normal","outcome":"term","duration_ms":90,"finished_at":"not-a-timestamp"}]}
J
OUT=$(handle_cleanup_stats_command "$ROOT")
# ok(50) + dirty-events valid(60) = 2 provider samples; the 4 bad events dropped.
assert_eq "invalid events within a valid file are dropped" "2" "$(f "$OUT" .kinds.provider.sample_count)"

# ---------------------------------------------------------------------------
note "== empty input =="
ROOT="$TMP/empty"; mkdir -p "$ROOT"
OUT=$(handle_cleanup_stats_command "$ROOT"); rc=$?
assert_eq "empty root returns 0" 0 "$rc"
assert_eq "empty runs_scanned" "0" "$(f "$OUT" .runs_scanned)"
assert_eq "empty provider sample_count" "0" "$(f "$OUT" .kinds.provider.sample_count)"
assert_eq "empty provider p50 is null" "null" "$(f "$OUT" .kinds.provider.p50_duration_ms)"
assert_eq "empty provider max is null" "null" "$(f "$OUT" .kinds.provider.max_duration_ms)"
assert_eq "empty provider term_rate is null" "null" "$(f "$OUT" .kinds.provider.term_rate)"
# Nonexistent root still emits valid, well-formed JSON.
OUT=$(handle_cleanup_stats_command "$TMP/does-not-exist"); rc=$?
assert_eq "missing root returns 0" 0 "$rc"
assert_eq "missing root runs_scanned" "0" "$(f "$OUT" .runs_scanned)"

# ---------------------------------------------------------------------------
note "== percentile edges (nearest-rank) =="
ROOT="$TMP/pctl"
# Single sample: p50 == p95 == max == the value.
write_artifact "$ROOT/one" <<'J'
{"schema_version":1,"artifact":"ralph_process_cleanup","events":[
 {"kind":"provider","trigger":"normal","outcome":"term","duration_ms":42,"finished_at":"2026-07-14T00:00:00Z"}]}
J
OUT=$(handle_cleanup_stats_command "$ROOT")
assert_eq "single-sample p50" "42" "$(f "$OUT" .kinds.provider.p50_duration_ms)"
assert_eq "single-sample p95" "42" "$(f "$OUT" .kinds.provider.p95_duration_ms)"
# Ten distinct samples 10..100: p50 rank ceil(5.0)=5 -> 50; p95 rank ceil(9.5)=10 -> 100.
ROOT="$TMP/pctl10"
{
  printf '{"schema_version":1,"artifact":"ralph_process_cleanup","events":['
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [[ $i -gt 1 ]] && printf ','
    printf '{"kind":"provider","trigger":"normal","outcome":"already_exited","duration_ms":%d,"finished_at":"2026-07-14T00:00:00Z"}' $((i*10))
  done
  printf ']}'
} | write_artifact "$ROOT/ten"
OUT=$(handle_cleanup_stats_command "$ROOT")
assert_eq "N=10 p50 (rank 5)" "50" "$(f "$OUT" .kinds.provider.p50_duration_ms)"
assert_eq "N=10 p95 (rank 10)" "100" "$(f "$OUT" .kinds.provider.p95_duration_ms)"
assert_eq "N=10 max" "100" "$(f "$OUT" .kinds.provider.max_duration_ms)"

# ---------------------------------------------------------------------------
note "== retention boundary: only immediate children under run root =="
ROOT="$TMP/retention"
for r in 1 2 3 4 5; do
  write_artifact "$ROOT/run-$r" <<J
{"schema_version":1,"artifact":"ralph_process_cleanup","events":[
 {"kind":"provider","trigger":"normal","outcome":"term","duration_ms":$((r*10)),"finished_at":"2026-07-14T00:00:00Z"}]}
J
done
# A deeper, nested artifact (grandchild) must NOT be scanned.
write_artifact "$ROOT/deep/nested" <<'J'
{"schema_version":1,"artifact":"ralph_process_cleanup","events":[
 {"kind":"provider","trigger":"normal","outcome":"kill","duration_ms":9999,"finished_at":"2026-07-14T00:00:00Z"}]}
J
# A sibling artifact OUTSIDE the run root must NOT be scanned.
write_artifact "$TMP/outside-run-root" <<'J'
{"schema_version":1,"artifact":"ralph_process_cleanup","events":[
 {"kind":"provider","trigger":"normal","outcome":"kill","duration_ms":8888,"finished_at":"2026-07-14T00:00:00Z"}]}
J
OUT=$(handle_cleanup_stats_command "$ROOT")
assert_eq "scans exactly the 5 immediate run dirs" "5" "$(f "$OUT" .runs_scanned)"
assert_eq "provider samples == 5 (no nested/outside)" "5" "$(f "$OUT" .kinds.provider.sample_count)"
# The out-of-root / nested KILL durations (9999, 8888) must be absent from the max.
assert_eq "nested/outside durations excluded from max" "50" "$(f "$OUT" .kinds.provider.max_duration_ms)"

# ---------------------------------------------------------------------------
note "== redaction: no per-event detail, commands, PIDs, paths, or timestamps =="
ROOT="$TMP/redact"
write_artifact "$ROOT/run-SENSITIVE-NAME" <<'J'
{"schema_version":1,"artifact":"ralph_process_cleanup","events":[
 {"kind":"provider","trigger":"normal","outcome":"term","duration_ms":123,"finished_at":"2026-07-14T09:09:09Z",
  "command":"SECRETCOMMAND --token=abc","pid":424242,"path":"/etc/shadow-XYZZY"}]}
J
OUT=$(handle_cleanup_stats_command "$ROOT")
grep -q "SECRETCOMMAND" <<<"$OUT" && bad "leaked event command" || ok "no event command in output"
grep -q "424242" <<<"$OUT" && bad "leaked event pid" || ok "no event pid in output"
grep -q "XYZZY" <<<"$OUT" && bad "leaked event path" || ok "no event path in output"
grep -q "09:09:09" <<<"$OUT" && bad "leaked event timestamp" || ok "no event timestamp in output"
grep -q "SENSITIVE-NAME" <<<"$OUT" && bad "leaked run id" || ok "no run id in output"
jq -e 'has("events") | not' <<<"$OUT" >/dev/null 2>&1 && ok "no per-event array in output" || bad "output exposed events array"
# The one valid event is still counted, so we know it WAS read (not just filtered out).
assert_eq "redacted event still counted" "123" "$(f "$OUT" .kinds.provider.max_duration_ms)"

# ---------------------------------------------------------------------------
note "== symlink safety: symlinked run dirs and artifacts are not followed =="
ROOT="$TMP/symlink"; mkdir -p "$ROOT"
# Real target holding a sentinel value, outside the run root.
TARGET="$TMP/symlink-target"
write_artifact "$TARGET" <<'J'
{"schema_version":1,"artifact":"ralph_process_cleanup","events":[
 {"kind":"provider","trigger":"normal","outcome":"kill","duration_ms":77777,"finished_at":"2026-07-14T00:00:00Z"}]}
J
# (a) a symlinked run directory
ln -s "$TARGET" "$ROOT/symlinked-dir"
# (b) a real run dir whose artifact is a symlink to the sentinel file
mkdir -p "$ROOT/real-dir"
ln -s "$TARGET/process-cleanup.json" "$ROOT/real-dir/process-cleanup.json"
# (c) one genuinely valid run so the scan has something to count
write_artifact "$ROOT/good" <<'J'
{"schema_version":1,"artifact":"ralph_process_cleanup","events":[
 {"kind":"provider","trigger":"normal","outcome":"term","duration_ms":11,"finished_at":"2026-07-14T00:00:00Z"}]}
J
OUT=$(handle_cleanup_stats_command "$ROOT")
grep -q "77777" <<<"$OUT" && bad "followed a symlink to sentinel data" || ok "symlink sentinel not read"
assert_eq "only the real artifact scanned" "1" "$(f "$OUT" .runs_scanned)"
# The symlinked artifact (in the real dir) is skipped; the symlinked dir is ignored.
assert_eq "symlinked artifact counted as skipped" "1" "$(f "$OUT" .artifacts_skipped)"

# ---------------------------------------------------------------------------
printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
