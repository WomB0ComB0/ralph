#!/bin/bash
# TDD harness for the swarm scheduler hardening (bounded concurrency + reaping + history).
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export VERBOSE=false
# shellcheck disable=SC1090
source "$R/lib/utils.sh"
source "$R/lib/engine.sh"
source "$R/lib/tools.sh"
set +eu

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (exp [$2] got [$3])"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
AG="$TMP/agents"; mkdir -p "$AG"
export RALPH_SWARM_ROOT="$TMP/swarm"

mk_agent() { local id="$1" status="$2" pid="$3"; mkdir -p "$AG/$id"; echo "$status" > "$AG/$id/status"; [[ -n "$pid" ]] && echo "$pid" > "$AG/$id/pid"; }

sleep 30 & LIVE=$!
{ sleep 5 & DEAD=$!; } 2>/dev/null; kill "$DEAD" 2>/dev/null; wait "$DEAD" 2>/dev/null  # reliably-dead pid

echo "== swarm_active_count: counts only RUNNING with a live pid =="
mk_agent live_one RUNNING "$LIVE"
mk_agent dead_one RUNNING "$DEAD"
mk_agent off_one  OFF     "$LIVE"
eq "active count = 1 (live RUNNING only)" 1 "$(swarm_active_count "$AG")"

echo "== reap_dead_agents: RUNNING+dead pid -> OFF =="
reap_dead_agents "$AG"
eq "dead RUNNING agent reaped to OFF" OFF "$(cat "$AG/dead_one/status")"
eq "live RUNNING agent untouched"     RUNNING "$(cat "$AG/live_one/status")"
[[ ! -f "$AG/dead_one/pid" ]] && ok "reaped agent's pid file removed" || bad "pid file lingers"

echo "== swarm_wait_for_slot: returns immediately when under cap =="
rm -rf "$AG"; mkdir -p "$AG"
mk_agent a RUNNING "$LIVE"
( swarm_wait_for_slot 3 "$AG" ); eq "slot available under cap -> rc 0" 0 "$?"

echo "== swarm_wait_for_slot: reaps dead to free a slot, then returns =="
rm -rf "$AG"; mkdir -p "$AG"
mk_agent d1 RUNNING "$DEAD"
mk_agent d2 RUNNING "$DEAD"
export RALPH_SWARM_SLOT_TIMEOUT=3
( swarm_wait_for_slot 1 "$AG" ); eq "dead agents reaped -> slot frees -> rc 0" 0 "$?"

echo "== swarm_history_append: structured run-history line =="
swarm_history_append spawn agentX "role=engineer"
hist="$RALPH_SWARM_ROOT/history.jsonl"
[[ -f "$hist" ]] && ok "history file written" || bad "no history file"
if command -v jq >/dev/null; then
  eq "history event recorded" spawn "$(tail -1 "$hist" | jq -r .event)"
  eq "history agent recorded" agentX "$(tail -1 "$hist" | jq -r .agent)"
fi

kill "$LIVE" 2>/dev/null
printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
