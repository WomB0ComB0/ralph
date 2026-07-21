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

printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
