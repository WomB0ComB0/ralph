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

echo "TOTAL test_memory: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
