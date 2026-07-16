#!/bin/bash
# Harness for resq-software public org automation scripts.
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set +eu
IFS=$' \t\n'

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected [$2] got [$3])"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/config" "$TMP/state"

cat > "$TMP/bin/gh" <<'SH'
#!/bin/sh
if [ "$1 $2 $3" = "repo list resq-software" ] || [ "$1 $2 $3" = "repo list other-org" ]; then
  cat <<'JSON'
[
  {"nameWithOwner":"resq-software/live","isArchived":false,"isPrivate":false},
  {"nameWithOwner":"resq-software/archived","isArchived":true,"isPrivate":false},
  {"nameWithOwner":"resq-software/private","isArchived":false,"isPrivate":true},
  {"nameWithOwner":"resq-software/live","isArchived":false,"isPrivate":false}
]
JSON
  exit 0
fi
printf 'unexpected gh args: %s\n' "$*" >&2
exit 9
SH
chmod +x "$TMP/bin/gh"

cat > "$TMP/ralph.sh" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$RALPH_CALL_LOG"
case "$1 $2" in
  "synapse live-test") exit "${RALPH_SYN_RC:-0}" ;;
  "triage "*) exit 0 ;;
  "triage --suggest") exit 0 ;;
  "triage --fix-ci") exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$TMP/ralph.sh"

export PATH="$TMP/bin:$PATH"
export XDG_CONFIG_HOME="$TMP/config" XDG_STATE_HOME="$TMP/state"
export RALPH_CALL_LOG="$TMP/ralph-calls.log"

echo "== resq-public-targets =="
out=$("$R/scripts/resq-public-targets" --org resq-software)
eq "filters active public repos and dedupes" "resq-software/live" "$out"
"$R/scripts/resq-public-targets" --org resq-software --include-archived --write "$TMP/targets" >/dev/null
eq "--write creates target file" $'resq-software/live\nresq-software/archived' "$(cat "$TMP/targets")"
"$R/scripts/resq-public-targets" --limit nope >/dev/null 2>&1 && bad "invalid limit accepted" || ok "invalid limit rejected"

echo "== resq-org-patrol =="
: > "$RALPH_CALL_LOG"
RALPH_BIN="$TMP/ralph.sh" "$R/scripts/resq-org-patrol" --mode report --org resq-software --targets-file "$TMP/patrol.targets" >/dev/null 2>&1; rc=$?
eq "report patrol exits 0" 0 "$rc"
eq "patrol refreshes targets" "resq-software/live" "$(cat "$TMP/patrol.targets")"
grep -qx 'synapse live-test ralph' "$RALPH_CALL_LOG" && ok "patrol runs synapse live-test by default" || bad "missing synapse check"
grep -qx 'triage' "$RALPH_CALL_LOG" && ok "report mode runs read-only triage" || bad "report mode did not run triage"

: > "$RALPH_CALL_LOG"
RALPH_BIN="$TMP/ralph.sh" "$R/scripts/resq-org-patrol" --mode suggest-apply --org resq-software --targets-file "$TMP/patrol.targets" --no-synapse-check >/dev/null 2>&1; rc=$?
eq "suggest-apply patrol exits 0" 0 "$rc"
! grep -q '^synapse live-test' "$RALPH_CALL_LOG" && ok "--no-synapse-check skips live-test" || bad "synapse check ran despite flag"
grep -qx 'triage --suggest --apply' "$RALPH_CALL_LOG" && ok "suggest-apply maps to triage issue write mode" || bad "wrong suggest-apply triage args"

RALPH_BIN="$TMP/ralph.sh" "$R/scripts/resq-org-patrol" --mode bogus --org resq-software --targets-file "$TMP/patrol.targets" --no-synapse-check >/dev/null 2>&1 && bad "invalid patrol mode accepted" || ok "invalid patrol mode rejected"

printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
