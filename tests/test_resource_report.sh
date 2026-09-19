#!/bin/bash
# TDD harness for read-only Ralph resource reporting.
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "$R/lib/utils.sh"
# shellcheck disable=SC1090
source "$R/lib/resources.sh"
set +eu

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected [$2] got [$3])"; fi; }
contains() { if grep -q -- "$2" <<<"$3"; then ok "$1"; else bad "$1 (missing [$2] in [$3])"; fi; }

if ! command -v jq >/dev/null 2>&1; then
    bad "jq unavailable; resource report requires jq"
    printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
    exit 1
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export PROJECT_DIR="$TMP/project" XDG_STATE_HOME="$TMP/state" XDG_CONFIG_HOME="$TMP/config"
mkdir -p "$PROJECT_DIR/.ralph/artifacts/signals" "$PROJECT_DIR/.ralph/runs/run-a" "$PROJECT_DIR/.ralph/beads" "$XDG_STATE_HOME/ralph/demo" "$XDG_CONFIG_HOME/ralph"
printf '{}\n' > "$PROJECT_DIR/.ralph/artifacts/signals/a.json"
printf '{}\n' > "$PROJECT_DIR/.ralph/artifacts/signals/b.json"
printf 'run log\n' > "$PROJECT_DIR/.ralph/runs/run-a/ralph.log"
printf 'beads\n' > "$PROJECT_DIR/.ralph/beads/tasks.db"
printf 'patrol\n' > "$XDG_STATE_HOME/ralph/demo/patrol-20260721T000000Z.log"

out=$(handle_resource_command report); rc=$?
eq "resource report exits 0" 0 "$rc"
jq -e '.artifact=="ralph_resource_report" and .schema_version==1' <<<"$out" >/dev/null && ok "resource report emits valid artifact JSON" || bad "bad resource JSON: $out"
eq "signal file count" 2 "$(jq -r '.disk.signal_files' <<<"$out")"
eq "run dir count" 1 "$(jq -r '.disk.run_dirs' <<<"$out")"
jq -e '.disk.ralph_bytes > 0 and .disk.latest_patrol_log_bytes > 0' <<<"$out" >/dev/null && ok "resource report records positive disk sizes" || bad "missing disk sizes: $out"
jq -e '.system.load.load1 != null and .system.memory.total_kib != null and .system.timers.active_timer_count >= 0 and .system.synapse.process_count >= 0' <<<"$out" >/dev/null && ok "resource report records system snapshot" || bad "missing system snapshot: $out"
handle_resource_command wat >/dev/null 2>&1 && bad "invalid resource subcommand accepted" || ok "invalid resource subcommand rejected"

_resource_load_json() { printf '{"load1":2.5,"load5":1.0,"load15":0.5}'; }
_resource_memory_json() { printf '{"total_kib":1000,"used_kib":700,"available_kib":300}'; }
_resource_scratch_json() { printf '{"path":"/tmp","used_percent":50,"inode_used_percent":40}'; }

out=$(handle_resource_command report --max-load1 1 --max-memory-used-pct 60 --max-ralph-bytes 1 --max-run-dirs 0); rc=$?
eq "budgeted resource report exits 0" 0 "$rc"
eq "budget warning count" 4 "$(jq -r '.warnings | length' <<<"$out")"
jq -e '.ok == false and .budgets.max_ralph_bytes == 1 and .system.memory.used_percent == 70' <<<"$out" >/dev/null && ok "budget report records thresholds and derived memory percentage" || bad "bad budget report: $out"
contains "cpu budget warning present" '"kind": "cpu"' "$out"
contains "memory budget warning present" '"kind": "memory"' "$out"
contains "disk budget warning present" '"kind": "disk"' "$out"
contains "run-count budget warning present" '"kind": "runs"' "$out"

out=$(handle_resource_command report --max-run-dirs 0 --fail-on-warning); rc=$?
eq "fail-on-warning exits 3" 3 "$rc"
jq -e '.ok == false and (.warnings | length) == 1' <<<"$out" >/dev/null && ok "fail-on-warning still prints report JSON" || bad "fail-on-warning lost JSON: $out"
handle_resource_command report --max-run-dirs nope >/dev/null 2>&1 && bad "invalid run budget accepted" || ok "invalid run budget rejected"
handle_resource_command report --max-ralph-bytes nope >/dev/null 2>&1 && bad "invalid disk budget accepted" || ok "invalid disk budget rejected"

echo "== run-dir retention prune =="
PR=$(mktemp -d)
for t in 20260101T000000-1-a 20260102T000000-2-b 20260103T000000-3-c 20260104T000000-4-d; do mkdir -p "$PR/$t"; done
eq "prunes oldest beyond keep=2" 2 "$(_resource_prune_run_dirs "$PR" 2)"
eq "keeps the 2 newest by name" "20260103T000000-3-c 20260104T000000-4-d" "$(ls "$PR" 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//')"
PR2=$(mktemp -d); mkdir -p "$PR2/a" "$PR2/b"
eq "keep >= count prunes nothing" 0 "$(_resource_prune_run_dirs "$PR2" 5)"
eq "keep=0 disables" 0 "$(_resource_prune_run_dirs "$PR2" 0)"
eq "missing dir is a no-op" 0 "$(_resource_prune_run_dirs "$PR/nope" 2)"
rm -rf "$PR" "$PR2"
# wiring: the report command prunes when --prune-runs / RALPH_RESOURCE_RUN_RETENTION is set
RRB=$(mktemp -d); RR="$RRB/runs"; mkdir -p "$RR"
for t in 20260101T0-a 20260102T0-b 20260103T0-c 20260104T0-d 20260105T0-e; do mkdir -p "$RR/$t"; done
out=$(RALPH_RUN_ROOT="$RR" handle_resource_command report --prune-runs 3)
jq -e '.disk.run_dirs_pruned == 2' <<<"$out" >/dev/null && ok "report --prune-runs records run_dirs_pruned" || bad "wrong run_dirs_pruned: $(jq -c '.disk.run_dirs_pruned' <<<"$out")"
eq "report --prune-runs keeps newest 3 on disk" 3 "$(ls "$RR" 2>/dev/null | wc -l | tr -d ' ')"
handle_resource_command report --prune-runs nope >/dev/null 2>&1 && bad "invalid --prune-runs accepted" || ok "invalid --prune-runs rejected"
rm -rf "$RRB"

echo "== scratch filesystem awareness =="
out=$(handle_resource_command report)
jq -e '.system.scratch.used_percent == 50 and .system.scratch.inode_used_percent == 40 and .system.scratch.path == "/tmp"' <<<"$out" >/dev/null \
  && ok "report includes the system.scratch block" || bad "missing/incorrect system.scratch: $out"
jq -e '.budgets.max_scratch_used_percent == 90' <<<"$out" >/dev/null \
  && ok "scratch budget defaults to 90" || bad "scratch budget default wrong: $(jq -c .budgets <<<"$out")"
out=$(handle_resource_command report --max-scratch-pct 0)
jq -e '[.warnings[]?.kind] | any(.=="scratch")' <<<"$out" >/dev/null \
  && ok "over-budget scratch emits a scratch warning" || bad "no scratch warning at budget 0: $(jq -c .warnings <<<"$out")"
jq -e '.ok == false' <<<"$out" >/dev/null \
  && ok "scratch warning drops ok to false" || bad "ok not false with scratch warning"
out=$(handle_resource_command report --max-scratch-pct 100)
jq -e '[.warnings[]?.kind] | any(.=="scratch") | not' <<<"$out" >/dev/null \
  && ok "under-budget scratch emits no warning" || bad "unexpected scratch warning at budget 100"
out=$(handle_resource_command report --max-scratch-pct 30)
jq -e '[.warnings[]?.metric] | any(.=="system.scratch.inode_used_percent")' <<<"$out" >/dev/null \
  && ok "inode over-budget emits an inode scratch warning" || bad "no inode scratch warning at budget 30"
handle_resource_command report --max-scratch-pct nope >/dev/null 2>&1 \
  && bad "invalid scratch budget accepted" || ok "invalid scratch budget rejected"

summary_json='{"ok":false,"disk":{"ralph_bytes":3400000,"run_dirs":307},"system":{"memory":{"used_percent":19.5},"load":{"load1":2.8}},"history":{"file":"/tmp/history.jsonl"},"trend":{"slope":{"percent_per_sample":{"ralph_bytes":0,"load1":23.3}}},"warnings":[{"kind":"slope"},{"kind":"disk"}]}'
out=$(handle_resource_command summary --history "$TMP/history.jsonl" <<<"$summary_json"); rc=$?
eq "resource summary exits 0" 0 "$rc"
eq "resource summary formats compact band" "resource summary: band=sustained-growth ok=false warnings=2 disk=3.2M runs=307 memory=19.5% load1=2.8 slope_max=23.3%/sample history=$TMP/history.jsonl" "$out"
printf '%s
' "$summary_json" > "$TMP/summary.json"
out=$(handle_resource_command summary "$TMP/summary.json"); rc=$?
eq "resource summary accepts report file" 0 "$rc"
contains "resource summary uses report history fallback" 'history=/tmp/history.jsonl' "$out"
out=$(handle_resource_command summary --json --history "$TMP/history.jsonl" "$TMP/summary.json"); rc=$?
eq "resource summary json exits 0" 0 "$rc"
jq -e --arg history "$TMP/history.jsonl" '.artifact == "ralph_resource_summary" and .schema_version == 1 and .band == "sustained-growth" and .warning_count == 2 and .has_slope_warning == true and .history == $history and .metrics.slope_max_percent_per_sample == 23.3 and .display.disk == "3.2M"' <<<"$out" >/dev/null && ok "resource summary emits machine-readable JSON" || bad "bad summary JSON: $out"
handle_resource_command summary "$TMP/summary.json" "$TMP/summary.json" >/dev/null 2>&1 && bad "extra summary file accepted" || ok "extra summary file rejected"

history="$TMP/resource-history.jsonl"
printf '%s
' '{"schema_version":1,"artifact":"ralph_resource_snapshot","generated_at":"2026-07-21T00:00:00Z","disk":{"ralph_bytes":1,"run_dirs":1},"system":{"load1":1,"memory_used_percent":10}}' > "$history"
out=$(handle_resource_command report --record-history "$history" --history-retention 2 --max-growth-pct 10); rc=$?
eq "history resource report exits 0" 0 "$rc"
jq -e '.history.recorded == true and .history.retention == 2 and .trend.previous_at == "2026-07-21T00:00:00Z"' <<<"$out" >/dev/null && ok "history report records previous snapshot trend" || bad "history trend missing: $out"
jq -e '.warnings[] | select(.kind == "trend")' <<<"$out" >/dev/null && ok "trend budget warning present" || bad "missing trend warning: $out"
eq "history retention keeps two snapshots" 2 "$(wc -l < "$history" | tr -d '[:space:]')"
jq -e 'select(.artifact == "ralph_resource_snapshot") and .disk.ralph_bytes > 0 and .warning_count >= 1' <<<"$(tail -n 1 "$history")" >/dev/null && ok "history file stores compact snapshot" || bad "bad history snapshot: $(cat "$history")"
handle_resource_command report --history-retention nope >/dev/null 2>&1 && bad "invalid history retention accepted" || ok "invalid history retention rejected"

slope_history="$TMP/resource-slope-history.jsonl"
current_bytes=$(_resource_size_bytes "$PROJECT_DIR/.ralph")
small_bytes=$((current_bytes / 4))
[[ "$small_bytes" -lt 1 ]] && small_bytes=1
mid_bytes=$((current_bytes / 2))
cat > "$slope_history" <<JSON
{"schema_version":1,"artifact":"ralph_resource_snapshot","generated_at":"2026-07-21T00:00:00Z","disk":{"ralph_bytes":$small_bytes,"run_dirs":1},"system":{"load1":1,"memory_used_percent":10}}
{"schema_version":1,"artifact":"ralph_resource_snapshot","generated_at":"2026-07-21T01:00:00Z","disk":{"ralph_bytes":$mid_bytes,"run_dirs":1},"system":{"load1":1,"memory_used_percent":20}}
JSON
out=$(handle_resource_command report --record-history "$slope_history" --history-retention 4 --max-slope-pct 10 --slope-window 2); rc=$?
eq "slope resource report exits 0" 0 "$rc"
jq -e '.trend.slope.sample_count == 3 and .trend.slope.window == 2 and .budgets.max_slope_percent_per_sample == 10' <<<"$out" >/dev/null && ok "slope report records window metadata" || bad "slope metadata missing: $out"
jq -e '.warnings[] | select(.kind == "slope" and .metric == "trend.slope.percent_per_sample.ralph_bytes")' <<<"$out" >/dev/null && ok "slope budget warning present" || bad "missing slope warning: $out"
handle_resource_command report --max-slope-pct nope >/dev/null 2>&1 && bad "invalid slope budget accepted" || ok "invalid slope budget rejected"
handle_resource_command report --slope-window 0 >/dev/null 2>&1 && bad "invalid slope window accepted" || ok "invalid slope window rejected"

printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
