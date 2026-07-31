#!/bin/bash
# TDD harness for lib/synapse.sh helpers (pure, non-network parts).
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export VERBOSE=false
# shellcheck disable=SC1090
source "$R/lib/utils.sh"
source "$R/lib/synapse.sh"
set +eu

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (exp [$2] got [$3])"; fi; }

echo "== live-test probe doc_id is stable (self-cleaning) =="
# The persistence probe must reuse a STABLE doc_id so Synapse upserts one doc
# in place instead of accumulating one per run (issue #51).
eq "doc_id has the expected stable shape" "ralph-livetest-ralph-probe" "$(_syn_livetest_doc_id ralph)"
a=$(_syn_livetest_doc_id ralph); b=$(_syn_livetest_doc_id ralph)
eq "doc_id is identical across calls (no timestamp/nonce)" "$a" "$b"
eq "doc_id is per-agent" "ralph-livetest-codex-probe" "$(_syn_livetest_doc_id codex)"
eq "defaults to ralph agent" "ralph-livetest-ralph-probe" "$(_syn_livetest_doc_id)"

printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
