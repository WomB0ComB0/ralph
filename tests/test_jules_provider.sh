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
eq "jules resolves empty model" "" "$(resolve_model_for_tool jules engineer)"
_build_ai_cmd jules "" >/dev/null 2>&1; eq "jules stays out of local command builder" 1 "$?"

echo "== run_ai_tool dispatch =="
run_jules_remote() { printf 'stub remote\n' > "$5"; return 0; }
iteration=1 MAX_ITERATIONS=1 run_ai_tool jules "" "prompt" "$TMP/dispatch.log" "$TMP/dispatch.out"; rc=$?
eq "run_ai_tool dispatches jules provider" 0 "$rc"
eq "dispatch writes provider output" "stub remote" "$(tr -d '\n' < "$TMP/dispatch.out")"
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

printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
