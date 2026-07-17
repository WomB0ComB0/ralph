#!/bin/bash
# Jules provider harness: fixture-style tests, no real Jules API calls.
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export VERBOSE=false
# shellcheck disable=SC1090
source "$R/lib/utils.sh"
# shellcheck disable=SC1090
source "$R/lib/engine.sh"
# shellcheck disable=SC1090
source "$R/lib/jules.sh"
set +eu
IFS=$' \t\n'

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected [$2] got [$3])"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export PROJECT_DIR="$TMP/proj" RUN_DIR="$TMP/run" RUN_ID="jules-test" JULES_API_KEY=fake
export RALPH_JULES_SOURCE="sources/github-owner-repo" RALPH_JULES_STARTING_BRANCH=main
export RALPH_JULES_TIMEOUT=0 RALPH_JULES_POLL_INTERVAL=0
mkdir -p "$PROJECT_DIR" "$RUN_DIR"

echo "== tool wiring =="
_ralph_is_valid_tool jules && ok "jules is a valid tool" || bad "jules rejected as tool"
_ralph_is_valid_tool jules-cli && ok "jules-cli is a valid tool" || bad "jules-cli rejected as tool"
eq "jules resolves empty model" "" "$(resolve_model_for_tool jules engineer)"
eq "jules-cli resolves empty model" "" "$(resolve_model_for_tool jules-cli engineer)"
_build_ai_cmd jules "" >/dev/null 2>&1; eq "jules stays out of local command builder" 1 "$?"
_build_ai_cmd jules-cli "" >/dev/null 2>&1; eq "jules-cli stays out of local command builder" 1 "$?"

CHECK_LOG="$TMP/dependency-checks.log"; : > "$CHECK_LOG"
(
    command_exists() { printf '%s\n' "$1" >> "$CHECK_LOG"; return 0; }
    TOOL=jules-cli check_dependencies >/dev/null 2>&1
); rc=$?
eq "jules-cli dependency check succeeds with stubbed deps" 0 "$rc"
grep -qx 'jules' "$CHECK_LOG" && ok "jules-cli requires jules binary" || bad "jules-cli did not require jules binary"
! grep -qx 'jules-cli' "$CHECK_LOG" && ok "jules-cli does not require same-named binary" || bad "jules-cli incorrectly required jules-cli binary"

echo "== Jules CLI session id parsing =="
eq "jules-cli parses structured sessionId" "515151" "$(printf '{"sessionId":"515151","state":"CREATED"}\n' | jules_cli_extract_session_id)"
eq "jules-cli parses structured session name" "626262" "$(printf '{"session":{"name":"sessions/626262"}}\n' | jules_cli_extract_session_id)"
eq "jules-cli falls back to human output" "424242" "$(printf 'Created Jules session 424242 for owner/repo\n' | jules_cli_extract_session_id)"

echo "== run_ai_tool dispatch =="
run_jules_remote() { printf 'stub remote\n' > "$5"; return 0; }
run_jules_cli_remote() { printf 'stub cli remote\n' > "$5"; return 0; }
iteration=1 MAX_ITERATIONS=1 run_ai_tool jules "" "prompt" "$TMP/dispatch.log" "$TMP/dispatch.out"; rc=$?
eq "run_ai_tool dispatches jules provider" 0 "$rc"
eq "dispatch writes provider output" "stub remote" "$(tr -d '\n' < "$TMP/dispatch.out")"
iteration=1 MAX_ITERATIONS=1 run_ai_tool jules-cli "" "prompt" "$TMP/dispatch-cli.log" "$TMP/dispatch-cli.out"; rc=$?
eq "run_ai_tool dispatches jules-cli provider" 0 "$rc"
eq "dispatch writes cli provider output" "stub cli remote" "$(tr -d '\n' < "$TMP/dispatch-cli.out")"
# Restore the real provider functions after the dispatch probe.
# shellcheck disable=SC1090
source "$R/lib/jules.sh"

echo "== create payload modes =="
export RALPH_JULES_MODE=pr
payload=$(jules_create_payload "do work" "title" "$RALPH_JULES_SOURCE" main)
jq -e '.automationMode == "AUTO_CREATE_PR"' <<<"$payload" >/dev/null && ok "PR mode enables AUTO_CREATE_PR" || bad "PR mode missing AUTO_CREATE_PR"
export RALPH_JULES_MODE=patch
payload=$(jules_create_payload "do work" "title" "$RALPH_JULES_SOURCE" main)
jq -e 'has("automationMode") | not' <<<"$payload" >/dev/null && ok "patch mode omits AUTO_CREATE_PR" || bad "patch mode unexpectedly created PR"

echo "== PR mode creates once and resumes existing session =="
export RALPH_JULES_MODE=pr
CALL_LOG="$TMP/calls-pr.log"; CREATE_BODY="$TMP/create-pr.json"; : > "$CALL_LOG"
jules_api_request() {
    local method="$1" path="$2" body="${3:-}"
    printf '%s %s\n' "$method" "$path" >> "$CALL_LOG"
    if [[ "$method $path" == "POST /sessions" ]]; then
        printf '%s' "$body" > "$CREATE_BODY"
        jq -n '{name:"sessions/101", id:"101", state:"QUEUED", url:"https://jules.google/session/101", createTime:"2026-07-10T00:00:00Z"}'
    elif [[ "$method $path" == "GET /sessions/101" ]]; then
        jq -n '{name:"sessions/101", id:"101", state:"IN_PROGRESS", url:"https://jules.google/session/101", updateTime:"2026-07-10T00:01:00Z"}'
    else
        return 9
    fi
}
log="$TMP/pr.log"; out="$TMP/pr.out"; : > "$log"; : > "$out"
run_jules_remote jules "" "build a remote thing" "$log" "$out"; rc=$?
eq "waiting Jules session is successful progress" 0 "$rc"
grep -q "still running" "$out" && ok "waiting output written" || bad "waiting output missing"
eq "state file stores session" "sessions/101" "$(jq -r '.sessionName' "$(jules_state_file)")"
eq "remote progress marker set" 1 "${_RALPH_REMOTE_PROGRESS:-0}"
jq -e '.automationMode == "AUTO_CREATE_PR"' "$CREATE_BODY" >/dev/null && ok "create body requests PR automation" || bad "create body missing PR automation"
run_jules_remote jules "" "build a remote thing" "$log" "$out"; rc=$?
eq "resume run succeeds" 0 "$rc"
eq "resume did not create a second session" 1 "$(grep -c '^POST /sessions$' "$CALL_LOG")"

echo "== completed PR output =="
rm -rf "$RUN_DIR"; mkdir -p "$RUN_DIR"; CALL_LOG="$TMP/calls-complete.log"; : > "$CALL_LOG"
jules_api_request() {
    local method="$1" path="$2" body="${3:-}"
    printf '%s %s\n' "$method" "$path" >> "$CALL_LOG"
    if [[ "$method $path" == "POST /sessions" ]]; then
        jq -n '{name:"sessions/202", id:"202", state:"QUEUED"}'
    elif [[ "$method $path" == "GET /sessions/202" ]]; then
        jq -n '{name:"sessions/202", id:"202", state:"COMPLETED", outputs:[{pullRequest:{url:"https://github.com/owner/repo/pull/5", title:"Remote change"}}]}'
    else
        return 9
    fi
}
log="$TMP/complete.log"; out="$TMP/complete.out"; : > "$log"; : > "$out"
run_jules_remote jules "" "finish remotely" "$log" "$out"; rc=$?
eq "completed PR run succeeds" 0 "$rc"
grep -q "https://github.com/owner/repo/pull/5" "$out" && ok "PR URL surfaced" || bad "PR URL missing"
grep -q "<promise>COMPLETE</promise>" "$out" && ok "completed PR emits completion promise" || bad "completion promise missing"
eq "state file stores PR URL" "https://github.com/owner/repo/pull/5" "$(jq -r '.pullRequestUrl' "$(jules_state_file)")"

echo "== patch mode applies changeSet locally =="
rm -rf "$PROJECT_DIR" "$RUN_DIR"; mkdir -p "$PROJECT_DIR" "$RUN_DIR"
git -C "$PROJECT_DIR" init -q
git -C "$PROJECT_DIR" config user.email test@example.com
git -C "$PROJECT_DIR" config user.name "Jules Test"
printf 'old\n' > "$PROJECT_DIR/app.txt"
git -C "$PROJECT_DIR" add app.txt
git -C "$PROJECT_DIR" commit -q -m base
base=$(git -C "$PROJECT_DIR" rev-parse HEAD)
printf 'new\n' > "$PROJECT_DIR/app.txt"
patch=$(git -C "$PROJECT_DIR" diff -- app.txt)
git -C "$PROJECT_DIR" checkout -- app.txt
export RALPH_JULES_MODE=patch
ACTIVITIES="$TMP/activities.json"
jq -n --arg base "$base" --arg patch "$patch" '{
  activities: [
    { artifacts: [ { changeSet: { gitPatch: { baseCommitId: $base, unidiffPatch: $patch, suggestedCommitMessage: "Update app text" } } } ] }
  ]
}' > "$ACTIVITIES"
jules_api_request() {
    local method="$1" path="$2"
    if [[ "$method $path" == "POST /sessions" ]]; then
        jq -n '{name:"sessions/303", id:"303", state:"QUEUED"}'
    elif [[ "$method $path" == "GET /sessions/303" ]]; then
        jq -n '{name:"sessions/303", id:"303", state:"COMPLETED"}'
    elif [[ "$method $path" == "GET /sessions/303/activities?pageSize=100" ]]; then
        cat "$ACTIVITIES"
    else
        return 9
    fi
}
log="$TMP/patch.log"; out="$TMP/patch.out"; : > "$log"; : > "$out"
run_jules_remote jules "" "patch locally" "$log" "$out"; rc=$?
eq "patch mode run succeeds" 0 "$rc"
eq "patch changed file locally" "new" "$(tr -d '\n' < "$PROJECT_DIR/app.txt")"
eq "state marks patch applied" true "$(jq -r '.patchApplied' "$(jules_state_file)")"
grep -q "Suggested commit: Update app text" "$out" && ok "suggested commit surfaced" || bad "suggested commit missing"


echo "== Jules CLI mode creates once, waits, then pulls/apply =="
rm -rf "$RUN_DIR"; mkdir -p "$RUN_DIR" "$TMP/bin"
cat > "$TMP/bin/jules" <<'SH'
#!/bin/sh
set -eu
case "$1 $2" in
  "new --repo")
    repo="$3"
    prompt=$(cat)
    printf 'new repo=%s prompt=%s\n' "$repo" "$prompt" >> "$JULES_STUB_LOG"
    if [ "${JULES_CREATE_MODE:-human}" = "json" ]; then
      printf '{"sessionId":"515151","state":"CREATED","repo":"%s"}\n' "$repo"
    else
      printf 'Created Jules session 424242 for %s\n' "$repo"
    fi
    ;;
  "remote pull")
    shift 2
    session=""; apply=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --session) session="$2"; shift 2 ;;
        --apply) apply=1; shift ;;
        *) shift ;;
      esac
    done
    printf 'pull session=%s apply=%s\n' "$session" "$apply" >> "$JULES_STUB_LOG"
    case "${JULES_STUB_PULL:-success}" in
      waiting) printf 'Session %s is still running\n' "$session"; exit 1 ;;
      success) printf 'Applied result for session %s\n' "$session" ;;
      fail) printf 'authentication failed\n'; exit 2 ;;
    esac
    ;;
  *)
    printf 'unexpected jules args: %s\n' "$*" >&2
    exit 9
    ;;
esac
SH
chmod +x "$TMP/bin/jules"
export PATH="$TMP/bin:$PATH" JULES_STUB_LOG="$TMP/jules-cli.log" RALPH_JULES_CLI_REPO="owner/repo" RALPH_JULES_CLI_MODE=apply
: > "$JULES_STUB_LOG"
log="$TMP/cli.log"; out="$TMP/cli.out"; : > "$log"; : > "$out"
run_jules_cli_remote jules-cli "" "build via cli" "$log" "$out"; rc=$?
eq "jules-cli create succeeds" 0 "$rc"
eq "jules-cli state stores session" "424242" "$(jq -r '.sessionId' "$(jules_cli_state_file)")"
eq "jules-cli state provider" "jules-cli" "$(jq -r '.provider' "$(jules_cli_state_file)")"
grep -q 'new repo=owner/repo prompt=build via cli' "$JULES_STUB_LOG" && ok "jules-cli pipes prompt to new" || bad "jules-cli new did not receive prompt"
grep -q 'State: CREATED' "$out" && ok "jules-cli create output marks created" || bad "jules-cli create output missing state"
eq "jules-cli create remote progress" 1 "${_RALPH_REMOTE_PROGRESS:-0}"

rm -f "$(jules_cli_state_file)"
export JULES_CREATE_MODE=json
run_jules_cli_remote jules-cli "" "build via cli json" "$log" "$out"; rc=$?
eq "jules-cli create parses structured fixture" 0 "$rc"
eq "jules-cli structured state stores session" "515151" "$(jq -r '.sessionId' "$(jules_cli_state_file)")"
export JULES_CREATE_MODE=human

export JULES_STUB_PULL=waiting
run_jules_cli_remote jules-cli "" "build via cli" "$log" "$out"; rc=$?
eq "jules-cli waiting pull returns progress" 0 "$rc"
eq "jules-cli waiting state" "IN_PROGRESS" "$(jq -r '.state' "$(jules_cli_state_file)")"
grep -q 'Session 515151 is still running' "$out" && ok "jules-cli waiting output surfaced" || bad "jules-cli waiting output missing"

export JULES_STUB_PULL=success
run_jules_cli_remote jules-cli "" "build via cli" "$log" "$out"; rc=$?
eq "jules-cli completed pull succeeds" 0 "$rc"
eq "jules-cli completed state" "COMPLETED" "$(jq -r '.state' "$(jules_cli_state_file)")"
eq "jules-cli apply marks patchApplied" true "$(jq -r '.patchApplied' "$(jules_cli_state_file)")"
grep -q '<promise>COMPLETE</promise>' "$out" && ok "jules-cli completed emits promise" || bad "jules-cli completion promise missing"
grep -q 'pull session=515151 apply=1' "$JULES_STUB_LOG" && ok "jules-cli pull uses --apply" || bad "jules-cli pull did not apply"

printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
