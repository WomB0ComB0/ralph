#!/bin/bash
# TDD harness for lib/synapse.sh helpers (pure, non-network parts).
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export VERBOSE=false
# shellcheck disable=SC1090
source "$R/lib/utils.sh"
source "$R/lib/synapse.sh"
set +eu

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

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

echo "== _synapse_ingest_doc injects tenant_id and posts /documents.ingest =="
_synapse_call() { printf '%s|%s|%s' "$1" "$2" "$4" >"$TMP/ingest_call"; printf '{"status":"ingested","doc_id":"d1"}'; }
SYNAPSE_TENANT=acme
doc='{"doc_id":"d1","source_system":"ralph","source_uri":"ralph://x/1","title":"t","content_type":"text/plain","language":"en","owners":["agent:ralph"],"metadata":{"kind":"ralph_skill"},"content":"c"}'
resp=$(_synapse_ingest_doc "$doc")
IFS='|' read -r m p b <"$TMP/ingest_call"
eq "posts to /documents.ingest" "POST /documents.ingest" "$m $p"
eq "tenant_id injected into body" "acme" "$(printf '%s' "$b" | jq -r '.tenant_id')"
eq "doc_id preserved" "d1" "$(printf '%s' "$b" | jq -r '.doc_id')"
eq "returns response status" "ingested" "$(printf '%s' "$resp" | jq -r '.status')"

printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
