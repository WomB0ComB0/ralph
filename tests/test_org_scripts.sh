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
if [ "$1 $2" = "auth status" ]; then exit "${RALPH_GH_AUTH_RC:-0}"; fi
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
  "resource report")
    cat <<'JSON'
{"ok":false,"disk":{"ralph_bytes":3400000,"run_dirs":307},"system":{"memory":{"used_percent":19.5},"load":{"load1":2.8}},"trend":{"slope":{"percent_per_sample":{"ralph_bytes":0,"load1":23.3}}},"warnings":[{"kind":"slope","metric":"trend.slope.percent_per_sample.load1"},{"kind":"disk","metric":"disk.ralph_bytes"}]}
JSON
    exit 0
    ;;
  "resource summary")
    printf 'resource summary: band=sustained-growth ok=false warnings=2 disk=3.2M runs=307 memory=19.5%% load1=2.8 slope_max=23.3%%/sample history=%s
' "$4"
    exit 0
    ;;
  "triage "*)
    if [ "$1 $2 $3" = "triage --fix-ci --apply" ] || [ "$1 $2 $3" = "triage --fix-security --apply" ]; then
      printf 'targets:%s\n' "$(cat "$RALPH_TARGETS_FILE" 2>/dev/null)" >> "$RALPH_CALL_LOG"
    fi
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
RALPH_BIN="$TMP/ralph.sh" "$R/scripts/org-patrol" --mode report --org demo-org --targets-file "$TMP/patrol.targets" >"$TMP/patrol-report.out" 2>&1; rc=$?
eq "report patrol exits 0" 0 "$rc"
eq "patrol refreshes targets for requested org" "demo-org/live" "$(cat "$TMP/patrol.targets")"
grep -qx 'synapse live-test ralph' "$RALPH_CALL_LOG" && ok "patrol runs synapse live-test by default" || bad "missing synapse check"
grep -qx 'triage' "$RALPH_CALL_LOG" && ok "report mode runs read-only triage" || bad "report mode did not run triage"
grep -Eq '^resource report --record-history .*/state/ralph/demo-org/resource-history\.jsonl$' "$RALPH_CALL_LOG" && ok "patrol records resource history by default" || bad "missing resource history call: $(cat "$RALPH_CALL_LOG")"
grep -Eq '^resource summary --history .*/state/ralph/demo-org/resource-history\.jsonl$' "$RALPH_CALL_LOG" && ok "patrol uses reusable resource summary command" || bad "missing resource summary command: $(cat "$RALPH_CALL_LOG")"
grep -Eq '^resource summary: band=sustained-growth ok=false warnings=2 disk=3\.2M runs=307 memory=19\.5% load1=2\.8 slope_max=23\.3%/sample history=.*/state/ralph/demo-org/resource-history\.jsonl$' "$TMP/patrol-report.out" && ok "patrol prints compact resource summary" || bad "missing resource summary: $(cat "$TMP/patrol-report.out")"
summary_file="$XDG_STATE_HOME/ralph/demo-org/soak-summary.jsonl"
[[ -f "$summary_file" ]] && ok "patrol writes durable soak summary" || bad "missing soak summary: $summary_file"
eq "soak summary is mode 600" "600" "$(stat -c '%a' "$summary_file" 2>/dev/null)"
jq -e '.artifact == "ralph_org_patrol_soak_summary" and .schema_version == 1 and .org == "demo-org" and .mode == "report" and .target_count == 1 and .result.ok == true and .result.exit_code == 0 and .synapse.enabled == true and .synapse.rc == 0 and .triage.rc == 0 and .resource.enabled == true and .resource.rc == 0 and .resource.ok == false and .resource.warning_count == 2 and .resource.band == "sustained-growth" and (.resource.history_file | test("/state/ralph/demo-org/resource-history\\.jsonl$")) and (.log_file | test("/state/ralph/demo-org/patrol-"))' "$summary_file" >/dev/null && ok "soak summary captures patrol, Synapse, triage, resource, and log fields" || bad "bad soak summary: $(cat "$summary_file" 2>/dev/null)"
grep -Eq '^patrol soak summary recorded: ok=true exit=0 file=.*/state/ralph/demo-org/soak-summary\.jsonl$' "$TMP/patrol-report.out" && ok "patrol prints soak summary artifact path" || bad "missing soak summary line: $(cat "$TMP/patrol-report.out")"

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

: > "$RALPH_CALL_LOG"
RALPH_BIN="$TMP/ralph.sh" "$R/scripts/org-patrol" --mode fix-ci-apply --org demo-org --targets-file "$TMP/patrol.targets" --no-synapse-check --no-resource-history >"$TMP/patrol-fix-ci-apply-guard.out" 2>&1; rc=$?
eq "fix-ci-apply without code-write targets exits 0" 0 "$rc"
! grep -qx 'triage --fix-ci --apply' "$RALPH_CALL_LOG" && ok "fix-ci-apply skips triage without code-write opt-in" || bad "unguarded fix-ci-apply ran triage: $(cat "$RALPH_CALL_LOG")"
grep -q 'has no approved targets' "$TMP/patrol-fix-ci-apply-guard.out" && ok "fix-ci-apply explains missing code-write opt-in" || bad "missing code-write opt-in warning: $(cat "$TMP/patrol-fix-ci-apply-guard.out")"

: > "$RALPH_CALL_LOG"
RALPH_BIN="$TMP/ralph.sh" "$R/scripts/org-patrol" --mode fix-ci-apply --org demo-org --targets-file "$TMP/patrol.targets" --code-write-targets 'demo-org/live,other-org/live demo-org/live' --no-synapse-check --no-resource-history >"$TMP/patrol-fix-ci-apply-allowed.out" 2>&1; rc=$?
eq "fix-ci-apply with matching code-write target exits 0" 0 "$rc"
grep -qx 'triage --fix-ci --apply' "$RALPH_CALL_LOG" && ok "fix-ci-apply runs triage after code-write opt-in" || bad "guarded fix-ci-apply did not run triage: $(cat "$RALPH_CALL_LOG")"
grep -qx 'targets:demo-org/live' "$RALPH_CALL_LOG" && ok "fix-ci-apply narrows triage targets to approved discovered repos" || bad "fix-ci-apply did not narrow targets: $(cat "$RALPH_CALL_LOG")"
grep -q 'code-write target filter: 1 approved target(s)' "$TMP/patrol-fix-ci-apply-allowed.out" && ok "fix-ci-apply reports approved target count" || bad "missing approved target count: $(cat "$TMP/patrol-fix-ci-apply-allowed.out")"

: > "$RALPH_CALL_LOG"
RALPH_BIN="$TMP/ralph.sh" "$R/scripts/org-patrol" --mode fix-security-apply --org demo-org --targets-file "$TMP/patrol.targets" --code-write-targets 'other-org/live' --no-synapse-check --no-resource-history >"$TMP/patrol-fix-security-apply-empty.out" 2>&1; rc=$?
eq "fix-security-apply with no discovered approved target exits 0" 0 "$rc"
! grep -qx 'triage --fix-security --apply' "$RALPH_CALL_LOG" && ok "fix-security-apply skips triage when approved targets are absent from discovery" || bad "empty filtered fix-security-apply ran triage: $(cat "$RALPH_CALL_LOG")"

echo "== org-patrol runs verify-fixes after an apply fix pass =="
: > "$RALPH_CALL_LOG"
RALPH_BIN="$TMP/ralph.sh" "$R/scripts/org-patrol" --mode fix-ci-apply --org demo-org --targets-file "$TMP/patrol.targets" --code-write-targets 'demo-org/live' --no-synapse-check --no-resource-history >/dev/null 2>&1; rc=$?
grep -q 'triage --verify-fixes' "$RALPH_CALL_LOG" && ok "apply-mode patrol runs the verify-fixes pass" || bad "verify-fixes not run: $(cat "$RALPH_CALL_LOG")"
: > "$RALPH_CALL_LOG"
RALPH_BIN="$TMP/ralph.sh" "$R/scripts/org-patrol" --mode report --org demo-org --targets-file "$TMP/patrol.targets" --no-synapse-check --no-resource-history >/dev/null 2>&1
grep -q 'triage --verify-fixes' "$RALPH_CALL_LOG" && bad "report mode wrongly ran verify-fixes" || ok "report mode does not verify"

RALPH_BIN="$TMP/ralph.sh" "$R/scripts/org-patrol" --mode bogus --org demo-org --targets-file "$TMP/patrol.targets" --no-synapse-check >"$TMP/patrol-invalid.out" 2>&1; rc=$?
[[ "$rc" -ne 0 ]] && ok "invalid patrol mode rejected" || bad "invalid patrol mode accepted"
tail -n 1 "$summary_file" | jq -e '.result.ok == false and .result.exit_code == 2 and .timing.elapsed_source == "monotonic" and (.elapsed_seconds | type == "number") and (.wall_elapsed_seconds | type == "number") and .synapse.enabled == false and .synapse.rc == null and .triage.rc == null and .resource.band == null and (.log_file | test("/state/ralph/demo-org/patrol-"))' >/dev/null && ok "failed patrol still records soak summary exit status" || bad "bad failed-patrol soak summary: $(tail -n 1 "$summary_file" 2>/dev/null)"
cat > "$TMP/soak-fixture.jsonl" <<'JSON'
{"artifact":"ralph_org_patrol_soak_summary","schema_version":1,"org":"demo-org","mode":"report","started_at":"2026-07-22T00:00:00Z","ended_at":"2026-07-22T00:00:10Z","elapsed_seconds":10,"wall_elapsed_seconds":10,"timing":{"elapsed_source":"monotonic","elapsed_milliseconds":10000,"wall_elapsed_seconds":10},"log_file":"/tmp/patrol-1.log","target_count":2,"result":{"ok":true,"exit_code":0},"synapse":{"enabled":true,"ok":true,"rc":0},"triage":{"ok":true,"rc":0},"resource":{"enabled":true,"ok":true,"rc":0,"warning_count":0,"band":"normal","history_file":"/tmp/history.jsonl"}}
not-json
{"artifact":"ralph_org_patrol_soak_summary","schema_version":1,"org":"demo-org","mode":"report","started_at":"2026-07-22T00:00:20Z","ended_at":"2026-07-23T03:46:59Z","elapsed_seconds":99999,"log_file":"/tmp/patrol-legacy.log","target_count":2,"result":{"ok":true,"exit_code":0},"synapse":{"enabled":true,"ok":true,"rc":0},"triage":{"ok":true,"rc":0},"resource":{"enabled":true,"ok":true,"rc":0,"warning_count":0,"band":"normal","history_file":"/tmp/history.jsonl"}}
{"artifact":"ralph_org_patrol_soak_summary","schema_version":1,"org":"demo-org","mode":"report","started_at":"2026-07-22T00:01:00Z","ended_at":"2026-07-22T00:01:25Z","elapsed_seconds":25,"wall_elapsed_seconds":25,"timing":{"elapsed_source":"monotonic","elapsed_milliseconds":25000,"wall_elapsed_seconds":25},"log_file":"/tmp/patrol-2.log","target_count":2,"result":{"ok":false,"exit_code":75},"synapse":{"enabled":true,"ok":false,"rc":1},"triage":{"ok":false,"rc":75},"resource":{"enabled":true,"ok":false,"rc":3,"warning_count":2,"band":"warning","history_file":"/tmp/history.jsonl"}}
{"artifact":"ralph_org_patrol_soak_summary","schema_version":1,"org":"demo-org","mode":"report","started_at":"2026-07-22T00:02:00Z","ended_at":"2026-07-22T00:02:07Z","elapsed_seconds":7,"wall_elapsed_seconds":40733,"timing":{"elapsed_source":"monotonic","elapsed_milliseconds":7000,"wall_elapsed_seconds":40733},"log_file":"/tmp/patrol-3.log","target_count":2,"result":{"ok":true,"exit_code":0},"synapse":{"enabled":false,"ok":null,"rc":null},"triage":{"ok":true,"rc":0},"resource":{"enabled":true,"ok":false,"rc":0,"warning_count":1,"band":"sustained-growth","history_file":"/tmp/history.jsonl"}}
JSON
out=$("$R/scripts/org-soak-summary" --org demo-org --file "$TMP/soak-fixture.jsonl" --recent 2); rc=$?
eq "org soak summary exits 0" 0 "$rc"
eq "org soak summary prints compact rollup" "org soak summary: org=demo-org cycles=4 failures=1 synapse_failures=1 triage_failures=1 resource_warning_runs=2 worst_elapsed=25s worst_wall_elapsed=99999s legacy_elapsed_records=1 last_band=sustained-growth last_exit=0 recent_synapse_rc=[1,null] file=$TMP/soak-fixture.jsonl" "$out"
out=$("$R/scripts/org-soak-summary" --org demo-org --file "$TMP/soak-fixture.jsonl" --recent 2 --json); rc=$?
eq "org soak summary json exits 0" 0 "$rc"
jq -e '.artifact == "ralph_org_patrol_soak_rollup" and .schema_version == 1 and .org == "demo-org" and .cycles == 4 and .failures == 1 and .synapse_failures == 1 and .triage_failures == 1 and .resource_warning_runs == 2 and .worst_elapsed_seconds == 25 and .worst_wall_elapsed_seconds == 99999 and .legacy_elapsed_records == 1 and .recent_synapse_rc == [1,null] and .resource_bands.normal == 2 and .resource_bands.warning == 1 and .resource_bands["sustained-growth"] == 1 and .skipped_lines == 1 and .last.resource_band == "sustained-growth" and .last.elapsed_source == "monotonic" and .last.wall_elapsed_seconds == 40733 and .last.log_file == "/tmp/patrol-3.log"' <<<"$out" >/dev/null && ok "org soak summary emits machine-readable rollup" || bad "bad org soak summary json: $out"
"$R/scripts/org-soak-summary" --org demo-org --file "$TMP/soak-fixture.jsonl" --recent 0 >/dev/null 2>&1 && bad "org soak summary accepted zero recent" || ok "org soak summary rejects zero recent"
"$R/scripts/org-soak-summary" --file "$TMP/soak-fixture.jsonl" >/dev/null 2>&1 && bad "org soak summary accepted missing org" || ok "org soak summary requires org"
RALPH_BIN="$TMP/ralph.sh" "$R/scripts/org-patrol" --mode report --targets-file "$TMP/patrol.targets" --no-synapse-check >/dev/null 2>&1 && bad "missing patrol org accepted" || ok "missing patrol org rejected"


"$R/scripts/org-install-systemd" install --org demo-org --interval 45min --cpu-quota 25% --memory-max 1G --io-weight 100 >/dev/null 2>&1; rc=$?
eq "org installer with resource limits exits 0" 0 "$rc"
svc="$XDG_CONFIG_HOME/systemd/user/ralph-demo-org-patrol.service"
timer="$XDG_CONFIG_HOME/systemd/user/ralph-demo-org-patrol.timer"
grep -q '^CPUQuota=25%$' "$svc" && ok "installer writes CPUQuota" || bad "CPUQuota missing: $(cat "$svc" 2>/dev/null)"
grep -q '^MemoryMax=1G$' "$svc" && ok "installer writes MemoryMax" || bad "MemoryMax missing: $(cat "$svc" 2>/dev/null)"
grep -q '^IOWeight=100$' "$svc" && ok "installer writes IOWeight" || bad "IOWeight missing: $(cat "$svc" 2>/dev/null)"
grep -q '^RALPH_ORG_SOAK_SUMMARY_FILE=.*/state/ralph/demo-org/soak-summary.jsonl$' "$XDG_CONFIG_HOME/ralph/demo-org-patrol.env" && ok "installer configures soak summary artifact path" || bad "soak summary env missing: $(cat "$XDG_CONFIG_HOME/ralph/demo-org-patrol.env" 2>/dev/null)"
grep -q '^OnUnitActiveSec=45min$' "$timer" && ok "installer preserves custom interval" || bad "custom interval missing: $(cat "$timer" 2>/dev/null)"
grep -q 'enable --now ralph-demo-org-patrol.timer' "$SYSTEMCTL_CALL_LOG" && ok "installer enables timer" || bad "timer enable not called: $(cat "$SYSTEMCTL_CALL_LOG")"

: > "$RALPH_CALL_LOG"
RALPH_BIN="$TMP/ralph.sh" "$R/scripts/resq-org-patrol" --mode report --targets-file "$TMP/resq-patrol.targets" --no-synapse-check >/dev/null 2>&1; rc=$?
eq "resq patrol wrapper exits 0" 0 "$rc"
eq "resq patrol wrapper defaults to resq-software" "resq-software/live" "$(cat "$TMP/resq-patrol.targets")"

echo "== org-patrol credential preflight =="
# Broken gh auth must abort the patrol EARLY (before target refresh + triage).
: > "$RALPH_CALL_LOG"
RALPH_GH_AUTH_RC=1 RALPH_BIN="$TMP/ralph.sh" "$R/scripts/org-patrol" --mode suggest-apply --org demo-org --targets-file "$TMP/pf.targets" >"$TMP/pf-fail.out" 2>&1; rc=$?
[[ "$rc" -ne 0 ]] && ok "broken gh auth aborts the patrol (rc=$rc)" || bad "patrol proceeded despite broken gh auth (rc=$rc)"
grep -qi 'preflight' "$TMP/pf-fail.out" && ok "preflight failure is reported" || bad "no preflight message: $(cat "$TMP/pf-fail.out")"
! grep -q 'triage' "$RALPH_CALL_LOG" && ok "failed preflight runs no triage" || bad "triage ran despite failed preflight"
tail -n1 "$summary_file" | jq -e '.preflight.ok == false and .result.ok == false' >/dev/null && ok "soak summary records the preflight failure" || bad "soak summary missing preflight failure: $(tail -n1 "$summary_file" 2>/dev/null)"

# Healthy gh auth -> preflight passes and the patrol proceeds.
: > "$RALPH_CALL_LOG"
RALPH_BIN="$TMP/ralph.sh" "$R/scripts/org-patrol" --mode report --org demo-org --targets-file "$TMP/pf.targets" --no-synapse-check --no-resource-history >/dev/null 2>&1; rc=$?
eq "healthy preflight patrol exits 0" 0 "$rc"
tail -n1 "$summary_file" | jq -e '.preflight.enabled == true and .preflight.ok == true' >/dev/null && ok "soak summary records preflight ok" || bad "soak summary missing preflight ok: $(tail -n1 "$summary_file" 2>/dev/null)"

# --no-preflight bypasses the gate even with broken gh auth.
: > "$RALPH_CALL_LOG"
RALPH_GH_AUTH_RC=1 RALPH_BIN="$TMP/ralph.sh" "$R/scripts/org-patrol" --mode report --org demo-org --targets-file "$TMP/pf.targets" --no-synapse-check --no-resource-history --no-preflight >/dev/null 2>&1; rc=$?
eq "--no-preflight bypasses the credential gate" 0 "$rc"
tail -n1 "$summary_file" | jq -e '.preflight.enabled == false' >/dev/null && ok "soak summary marks preflight disabled" || bad "preflight not marked disabled: $(tail -n1 "$summary_file" 2>/dev/null)"

printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
