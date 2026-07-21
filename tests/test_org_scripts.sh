#!/bin/bash
# Harness for public org automation scripts.
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
if [ "$1 $2" = "repo list" ]; then
  org="$3"
  if [ "$org" = "outage-org" ]; then
    printf 'HTTP 503: Service Unavailable\n' >&2
    exit 1
  fi
  if [ "$org" = "connect-org" ]; then
    printf 'error connecting to api.github.com\n' >&2
    exit 1
  fi
  case "$org" in demo-org|resq-software|other-org) ;; *) printf 'unexpected org: %s\n' "$org" >&2; exit 9 ;; esac
  cat <<JSON
[
  {"nameWithOwner":"$org/live","isArchived":false,"isPrivate":false},
  {"nameWithOwner":"$org/archived","isArchived":true,"isPrivate":false},
  {"nameWithOwner":"$org/private","isArchived":false,"isPrivate":true},
  {"nameWithOwner":"$org/live","isArchived":false,"isPrivate":false}
]
JSON
  exit 0
fi
printf 'unexpected gh args: %s\n' "$*" >&2
exit 9
SH
chmod +x "$TMP/bin/gh"

cat > "$TMP/bin/systemctl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$SYSTEMCTL_CALL_LOG"
exit 0
SH
chmod +x "$TMP/bin/systemctl"
export SYSTEMCTL_CALL_LOG="$TMP/systemctl-calls.log"

cat > "$TMP/ralph.sh" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$RALPH_CALL_LOG"
case "$1 $2" in
  "synapse live-test") exit "${RALPH_SYN_RC:-0}" ;;
  "triage "*)
    if [ "${RALPH_TRIAGE_GITHUB_503:-0}" = "1" ]; then
      printf 'WARNING: transient GitHub failure during triage: HTTP 503 Service Unavailable\n' >&2
    fi
    exit 0
    ;;
  "triage --suggest") exit 0 ;;
  "triage --fix-ci") exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$TMP/ralph.sh"

export PATH="$TMP/bin:$PATH"
export XDG_CONFIG_HOME="$TMP/config" XDG_STATE_HOME="$TMP/state"
export RALPH_CALL_LOG="$TMP/ralph-calls.log"

echo "== org-public-targets =="
out=$("$R/scripts/org-public-targets" --org demo-org)
eq "filters active public repos and dedupes for any org" "demo-org/live" "$out"
"$R/scripts/org-public-targets" --org demo-org --include-archived --write "$TMP/targets" >/dev/null
eq "--write creates target file" $'demo-org/live\ndemo-org/archived' "$(cat "$TMP/targets")"
"$R/scripts/org-public-targets" --limit nope >/dev/null 2>&1 && bad "invalid limit accepted" || ok "invalid limit rejected"
printf 'outage-org/cached\n' > "$TMP/cached.targets"
out=$("$R/scripts/org-public-targets" --org outage-org --write "$TMP/cached.targets" 2>"$TMP/outage.err"); rc=$?
eq "transient org discovery outage reuses cached targets" 0 "$rc"
eq "cached targets are printed during discovery outage" "outage-org/cached" "$out"
eq "cached targets are not overwritten by discovery outage" "outage-org/cached" "$(cat "$TMP/cached.targets")"
grep -q 'reusing cached targets' "$TMP/outage.err" && ok "discovery outage warns about cached targets" || bad "missing cached-target warning: $(cat "$TMP/outage.err")"
printf 'connect-org/cached\n' > "$TMP/connect.targets"
out=$("$R/scripts/org-public-targets" --org connect-org --write "$TMP/connect.targets" 2>"$TMP/connect.err"); rc=$?
eq "gh connection outage reuses cached targets" 0 "$rc"
eq "connection outage prints cached targets" "connect-org/cached" "$out"
grep -q 'reusing cached targets' "$TMP/connect.err" && ok "connection outage warns about cached targets" || bad "missing connection cached warning: $(cat "$TMP/connect.err")"
"$R/scripts/org-public-targets" --org outage-org --write "$TMP/missing.targets" >/dev/null 2>&1 && bad "uncached discovery outage accepted" || ok "uncached discovery outage fails closed"
RALPH_ORG=other-org "$R/scripts/org-public-targets" >/dev/null 2>&1 && ok "RALPH_ORG can supply org" || bad "RALPH_ORG did not supply org"
"$R/scripts/org-public-targets" >/dev/null 2>&1 && bad "missing org accepted" || ok "missing org rejected"
out=$("$R/scripts/resq-public-targets")
eq "resq public targets wrapper defaults to resq-software" "resq-software/live" "$out"

echo "== org-patrol =="
: > "$RALPH_CALL_LOG"
RALPH_BIN="$TMP/ralph.sh" "$R/scripts/org-patrol" --mode report --org demo-org --targets-file "$TMP/patrol.targets" >/dev/null 2>&1; rc=$?
eq "report patrol exits 0" 0 "$rc"
eq "patrol refreshes targets for requested org" "demo-org/live" "$(cat "$TMP/patrol.targets")"
grep -qx 'synapse live-test ralph' "$RALPH_CALL_LOG" && ok "patrol runs synapse live-test by default" || bad "missing synapse check"
grep -qx 'triage' "$RALPH_CALL_LOG" && ok "report mode runs read-only triage" || bad "report mode did not run triage"
grep -Eq '^resource report --record-history .*/state/ralph/demo-org/resource-history\.jsonl$' "$RALPH_CALL_LOG" && ok "patrol records resource history by default" || bad "missing resource history call: $(cat "$RALPH_CALL_LOG")"

: > "$RALPH_CALL_LOG"
RALPH_TRIAGE_GITHUB_503=1 RALPH_BIN="$TMP/ralph.sh" "$R/scripts/org-patrol" --mode report --org demo-org --targets-file "$TMP/patrol.targets" --no-resource-history >"$TMP/patrol-triage-503.out" 2>&1; rc=$?
eq "patrol survives triage-phase GitHub 503 degradation" 0 "$rc"
eq "triage 503 scenario runs Synapse before triage" $'synapse live-test ralph\ntriage' "$(cat "$RALPH_CALL_LOG")"
grep -q 'HTTP 503 Service Unavailable' "$TMP/patrol-triage-503.out" && ok "triage 503 warning is preserved in patrol output" || bad "missing triage 503 warning: $(cat "$TMP/patrol-triage-503.out")"

: > "$RALPH_CALL_LOG"
RALPH_BIN="$TMP/ralph.sh" "$R/scripts/org-patrol" --mode suggest-apply --org demo-org --targets-file "$TMP/patrol.targets" --no-synapse-check >/dev/null 2>&1; rc=$?
eq "suggest-apply patrol exits 0" 0 "$rc"
! grep -q '^synapse live-test' "$RALPH_CALL_LOG" && ok "--no-synapse-check skips live-test" || bad "synapse check ran despite flag"
grep -qx 'triage --suggest --apply' "$RALPH_CALL_LOG" && ok "suggest-apply maps to triage issue write mode" || bad "wrong suggest-apply triage args"

RALPH_BIN="$TMP/ralph.sh" "$R/scripts/org-patrol" --mode bogus --org demo-org --targets-file "$TMP/patrol.targets" --no-synapse-check >/dev/null 2>&1 && bad "invalid patrol mode accepted" || ok "invalid patrol mode rejected"
RALPH_BIN="$TMP/ralph.sh" "$R/scripts/org-patrol" --mode report --targets-file "$TMP/patrol.targets" --no-synapse-check >/dev/null 2>&1 && bad "missing patrol org accepted" || ok "missing patrol org rejected"


"$R/scripts/org-install-systemd" install --org demo-org --interval 45min --cpu-quota 25% --memory-max 1G --io-weight 100 >/dev/null 2>&1; rc=$?
eq "org installer with resource limits exits 0" 0 "$rc"
svc="$XDG_CONFIG_HOME/systemd/user/ralph-demo-org-patrol.service"
timer="$XDG_CONFIG_HOME/systemd/user/ralph-demo-org-patrol.timer"
grep -q '^CPUQuota=25%$' "$svc" && ok "installer writes CPUQuota" || bad "CPUQuota missing: $(cat "$svc" 2>/dev/null)"
grep -q '^MemoryMax=1G$' "$svc" && ok "installer writes MemoryMax" || bad "MemoryMax missing: $(cat "$svc" 2>/dev/null)"
grep -q '^IOWeight=100$' "$svc" && ok "installer writes IOWeight" || bad "IOWeight missing: $(cat "$svc" 2>/dev/null)"
grep -q '^OnUnitActiveSec=45min$' "$timer" && ok "installer preserves custom interval" || bad "custom interval missing: $(cat "$timer" 2>/dev/null)"
grep -q 'enable --now ralph-demo-org-patrol.timer' "$SYSTEMCTL_CALL_LOG" && ok "installer enables timer" || bad "timer enable not called: $(cat "$SYSTEMCTL_CALL_LOG")"

: > "$RALPH_CALL_LOG"
RALPH_BIN="$TMP/ralph.sh" "$R/scripts/resq-org-patrol" --mode report --targets-file "$TMP/resq-patrol.targets" --no-synapse-check >/dev/null 2>&1; rc=$?
eq "resq patrol wrapper exits 0" 0 "$rc"
eq "resq patrol wrapper defaults to resq-software" "resq-software/live" "$(cat "$TMP/resq-patrol.targets")"

printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
