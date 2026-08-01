#!/bin/bash
# TDD harness for cross-tick session continuity (lib/engine.sh session marker).
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
export STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
MARKER="$STATE_DIR/session.json"

echo "== _persist_session writes a marker only when opted in =="
RALPH_RESUME_SESSION=0 _persist_session claude
[[ ! -f "$MARKER" ]] && ok "no marker when RALPH_RESUME_SESSION=0" || bad "marker written without opt-in"
RALPH_RESUME_SESSION=1 RUN_ID=r-9 _persist_session claude
[[ -f "$MARKER" ]] && ok "marker written when opted in" || bad "no marker with opt-in"
eq "marker records the tool" claude "$(jq -r .tool "$MARKER")"

echo "== _restore_session pre-establishes on a fresh same-tool marker =="
unset _RALPH_SESSION_ESTABLISHED
RALPH_RESUME_SESSION=1 _restore_session claude
eq "fresh same-tool marker resumes" 1 "${_RALPH_SESSION_ESTABLISHED:-0}"

echo "== guards: tool mismatch / no opt-in / stale marker do NOT resume =="
unset _RALPH_SESSION_ESTABLISHED
RALPH_RESUME_SESSION=1 _restore_session opencode
eq "different tool does not resume" 0 "${_RALPH_SESSION_ESTABLISHED:-0}"
unset _RALPH_SESSION_ESTABLISHED
RALPH_RESUME_SESSION=0 _restore_session claude
eq "no resume without opt-in" 0 "${_RALPH_SESSION_ESTABLISHED:-0}"
# age the marker far past the TTL
jq '.established_at = 1' "$MARKER" > "$MARKER.tmp" && mv "$MARKER.tmp" "$MARKER"
unset _RALPH_SESSION_ESTABLISHED
RALPH_RESUME_SESSION=1 RALPH_SESSION_MAX_AGE_SECONDS=3600 _restore_session claude
eq "stale marker (age > TTL) does not resume" 0 "${_RALPH_SESSION_ESTABLISHED:-0}"

echo "== end-to-end: restore -> _should_resume true (the tick would --continue) =="
unset _RALPH_SESSION_ESTABLISHED
RALPH_RESUME_SESSION=1 RUN_ID=r-10 _persist_session claude
RALPH_RESUME_SESSION=1 _restore_session claude
RALPH_RESUME_SESSION=1 _should_resume claude && ok "_should_resume true after cross-tick restore" || bad "_should_resume false after restore"

printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
