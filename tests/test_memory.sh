#!/bin/bash
# TDD harness for genetic memory: extract <memory>…</memory> from agent output -> store -> recall.
# Makes the prompt's "save_memory" instruction real (it referenced a tool that never existed).
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export VERBOSE=false
# shellcheck disable=SC1090
source "$R/lib/utils.sh"
source "$R/lib/engine.sh"
set +eu

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (exp [$2] got [$3])"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "== _extract_memory_blocks: pulls <memory>…</memory> payloads (multi + multiline) =="
eq "single block"            "hello world" "$(printf '%s' '<memory>hello world</memory>' | _extract_memory_blocks)"
eq "surrounding text ignored" "keep this"  "$(printf '%s' 'noise <memory>keep this</memory> trailing' | _extract_memory_blocks)"
eq "two blocks"              "one|two"     "$(printf '%s' '<memory>one</memory> mid <memory>two</memory>' | _extract_memory_blocks | paste -sd'|' -)"
eq "multiline flattened"     "line a line b" "$(printf '%s\n' '<memory>' 'line a' 'line b' '</memory>' | _extract_memory_blocks)"
eq "no block -> empty"       ""            "$(printf '%s' 'no markers here' | _extract_memory_blocks)"
eq "empty block -> nothing"  ""            "$(printf '%s' '<memory>   </memory>' | _extract_memory_blocks)"

echo "== extract_and_store_memories -> genetic store, surfaced by recall_lessons =="
export MEMORY_DIR="$TMP/mem"; export GLOBAL_MEMORY_FILE="$MEMORY_DIR/global.json"
init_memory
extract_and_store_memories 'progress note <memory>Always run node -c before committing</memory> done'
grep -q 'Always run node -c before committing' "$GLOBAL_MEMORY_FILE" && ok "memory persisted to global.json" || bad "not persisted"
recall_lessons | grep -q 'Always run node -c before committing' && ok "recall_lessons surfaces the stored memory" || bad "recall did not surface it"
extract_and_store_memories 'just text, nothing worth saving here'
eq "a no-memory iteration stores nothing" "1" "$(jq '.lessons|length' "$GLOBAL_MEMORY_FILE")"

echo "== store_lesson: dedups + inits the store if missing =="
store_lesson "Always run node -c before committing"   # exact dup of the one above
eq "duplicate lesson not appended" "1" "$(jq '.lessons|length' "$GLOBAL_MEMORY_FILE")"
export MEMORY_DIR="$TMP/fresh"; export GLOBAL_MEMORY_FILE="$MEMORY_DIR/global.json"
store_lesson "bootstrap lesson"
grep -q 'bootstrap lesson' "$GLOBAL_MEMORY_FILE" 2>/dev/null && ok "store_lesson inits the store when absent" || bad "store_lesson lost the lesson (no init)"

printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
