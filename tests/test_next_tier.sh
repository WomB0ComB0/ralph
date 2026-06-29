#!/bin/bash
# TDD harness for NEXT-tier helpers (run_id, self-tuning review, tuning persistence).
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export VERBOSE=false
# shellcheck disable=SC1090
source "$R/lib/utils.sh"
source "$R/lib/engine.sh"
# engine.sh enables `set -euo pipefail` + a restrictive IFS; relax them so the
# harness can run all assertions and report failures instead of aborting early.
set +eu
IFS=$' \t\n'

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected [$2] got [$3])"; fi; }
assert_rc() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected rc=$2 got rc=$3)"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "== compute_run_id =="
rid=$(compute_run_id)
if [[ "$rid" =~ ^[0-9]{8}T[0-9]{6}-[0-9]+-[0-9]+$ ]]; then ok "run id has expected format"; else bad "run id format: got [$rid]"; fi
rid2=$(compute_run_id)
[[ -n "$rid2" ]] && ok "run id non-empty" || bad "run id empty"

echo "== _recommend_lazy_threshold =="
assert_eq "missing metrics -> 2" 2 "$(_recommend_lazy_threshold "$TMP/none.json")"
: > "$TMP/empty.json"
assert_eq "empty metrics -> 2" 2 "$(_recommend_lazy_threshold "$TMP/empty.json")"
{ for n in 1 2 3 1 2; do printf '{"iteration":%d,"lazy_streak":%d}\n' "$n" "$n"; done; } > "$TMP/stall.json"
assert_eq "stall-heavy -> 2" 2 "$(_recommend_lazy_threshold "$TMP/stall.json")"
{ for n in 1 2 3 4 5; do printf '{"iteration":%d,"lazy_streak":0}\n' "$n"; done; } > "$TMP/prog.json"
assert_eq "progress-heavy -> 3" 3 "$(_recommend_lazy_threshold "$TMP/prog.json")"
{ printf '{"lazy_streak":1}\n{"lazy_streak":1}\n{"lazy_streak":0}\n{"lazy_streak":0}\n{"lazy_streak":0}\n'; } > "$TMP/mix.json"
assert_eq "mixed 40pct -> 2" 2 "$(_recommend_lazy_threshold "$TMP/mix.json")"

echo "== write_tuning / load_tuning round-trip =="
sd="$TMP/state"; mkdir -p "$sd"
write_tuning "$sd" 3 17 42; rc=$?
assert_rc "write_tuning returns 0" 0 "$rc"
if jq empty "$sd/tuning.json" 2>/dev/null; then ok "tuning.json is valid JSON"; else bad "tuning.json invalid"; fi
assert_eq "tuning persists threshold" 3 "$(jq -r '.lazy_threshold' "$sd/tuning.json")"
unset LAZY_THRESHOLD
load_tuning "$sd"; rc=$?
assert_rc "load_tuning returns 0" 0 "$rc"
assert_eq "load_tuning exports LAZY_THRESHOLD" 3 "${LAZY_THRESHOLD:-unset}"
unset LAZY_THRESHOLD
load_tuning "$TMP/nostate"; rc=$?
assert_rc "load_tuning missing -> rc 1" 1 "$rc"
assert_eq "LAZY_THRESHOLD untouched when missing" "unset" "${LAZY_THRESHOLD:-unset}"

echo "== entry-point: light invocations must NOT be gated by check_dependencies =="
# ralph.sh must defer the dependency gate to main() (iterating path only), so --help and
# the read-only subcommands work on hosts missing the full toolchain (bc/bd/go/etc.).
grep -qE '^[[:space:]]*check_dependencies' "$R/ralph.sh" && bad "ralph.sh still calls check_dependencies before main (gates --help/subcommands)" || ok "ralph.sh defers check_dependencies to main"
HELP_RC=0; bash "$R/ralph.sh" --help >/dev/null 2>&1 || HELP_RC=$?
assert_rc "ralph.sh --help exits 0 without full deps" 0 "$HELP_RC"
SIG_RC=0; bash "$R/ralph.sh" signal ls >/dev/null 2>&1 || SIG_RC=$?
assert_rc "ralph.sh signal ls exits 0 without full deps" 0 "$SIG_RC"

printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
