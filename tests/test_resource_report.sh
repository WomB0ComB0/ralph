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

printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
