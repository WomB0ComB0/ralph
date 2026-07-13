#!/bin/bash
# Runtime verification harness: declared project commands and project-owned health ports.
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export VERBOSE=false
# shellcheck disable=SC1090
source "$R/lib/utils.sh"
# shellcheck disable=SC1090
source "$R/lib/processes.sh"
# shellcheck disable=SC1090
source "$R/lib/engine.sh"
set +eu
IFS=$' \t\n'

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected [$2] got [$3])"; fi; }
has_line() { grep -qxF "$2" <<<"$1"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/proj" "$TMP/outside"
PATH="$TMP/bin:$PATH"; export PATH

cat > "$TMP/proj/package.json" <<'JSON'
{
  "scripts": {
    "start": "node server.js",
    "test": "node --test",
    "build": "node build.js",
    "lint": "eslint ."
  }
}
JSON
cat > "$TMP/proj/ralph.json" <<'JSON'
{
  "commands": {
    "test": "npm test",
    "build": "npm run build",
    "smoke": "npm run smoke -- --quick",
    "ignored": "rm -rf /"
  }
}
JSON

echo "== collect_runtime_commands / runtime_command_allowed =="
cmds=$(collect_runtime_commands "$TMP/proj")
has_line "$cmds" "npm test" && ok "collects npm test" || bad "missing npm test"
has_line "$cmds" "npm run build" && ok "collects npm run build" || bad "missing npm run build"
has_line "$cmds" "npm run smoke -- --quick" && ok "collects ralph.json smoke command" || bad "missing smoke command"
[[ "$(grep -cxF 'npm test' <<<"$cmds")" == "1" ]] && ok "dedups duplicate commands" || bad "duplicate npm test"
runtime_command_allowed "npm test" && ok "allows npm test" || bad "rejects npm test"
runtime_command_allowed "npm run build -- --quick" && ok "allows npm run script args" || bad "rejects npm run args"
runtime_command_allowed "npm test; rm -rf /" && bad "allowed command injection" || ok "rejects command injection"
runtime_command_allowed "curl http://example.com" && bad "allowed unrelated command" || ok "rejects unrelated command"

echo "== verify_runtime runs declared Node commands =="
cat > "$TMP/bin/npm" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$NPM_LOG"
case "$*" in
  test|"run build"|"run lint"|"run smoke -- --quick") exit 0 ;;
  *) exit 9 ;;
esac
SH
chmod +x "$TMP/bin/npm"
export NPM_LOG="$TMP/npm.log"
export PROJECT_DIR="$TMP/proj"
export ARTIFACT_DIR="$TMP/artifacts"
export RALPH_VERIFICATION_FILE="$ARTIFACT_DIR/verification.json"
export RALPH_VERIFY_DECLARED_COMMANDS=1
unset RALPH_HEALTH_PORTS
: > "$NPM_LOG"
err=$(verify_runtime)
eq "verify_runtime succeeds when declared commands pass" "" "$err"
has_line "$(cat "$NPM_LOG")" "test" && ok "ran npm test" || bad "did not run npm test"
has_line "$(cat "$NPM_LOG")" "run build" && ok "ran npm run build" || bad "did not run npm run build"
has_line "$(cat "$NPM_LOG")" "run lint" && ok "ran npm run lint" || bad "did not run npm run lint"

cat > "$TMP/bin/npm" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$NPM_LOG"
[[ "$*" == "run build" ]] && exit 9
exit 0
SH
chmod +x "$TMP/bin/npm"
: > "$NPM_LOG"
err=$(verify_runtime)
[[ "$err" == *"Declared verification command failed: npm run build"* ]] && ok "failing declared command blocks runtime" || bad "missing declared command failure: $err"

if command -v timeout >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    echo "== verify_runtime records timeout evidence and diagnosis =="
    cat > "$TMP/bin/npm" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$NPM_LOG"
if [[ "$*" == "test" ]]; then
  echo "tests passed"
  sleep 2
fi
exit 0
SH
    chmod +x "$TMP/bin/npm"
    export RALPH_VERIFY_TIMEOUT=1
    : > "$NPM_LOG"
    err=$(verify_runtime)
    [[ "$err" == *"Declared verification command failed: npm test"* && "$err" == *"timed out after 1s"* && "$err" == *"open server/listener/timer"* ]] \
      && ok "timeout failure includes Node open-handle diagnosis" || bad "missing timeout diagnosis: $err"
    jq -e '.commands | any(.command=="npm test" and .timed_out==true and .exit_code==124)' "$RALPH_VERIFICATION_FILE" >/dev/null \
      && ok "verification evidence records timed-out command" || bad "verification evidence missing timeout record"
    unset RALPH_VERIFY_TIMEOUT
else
    ok "timeout or jq unavailable; skipped timeout evidence fixture"
fi

if command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    echo "== verify_runtime live smoke starts and tears down declared app =="
    printf '%s\n' 'hello live smoke' > "$TMP/proj/index.html"
    cat > "$TMP/bin/npm" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$NPM_LOG"
case "$*" in
  start) python3 -m http.server "${PORT:-18080}" --bind 127.0.0.1 ;;
  test|"run build"|"run lint"|"run smoke -- --quick") exit 0 ;;
  *) exit 9 ;;
esac
SH
    chmod +x "$TMP/bin/npm"
    export RALPH_LIVE_SMOKE=1
    export RALPH_LIVE_SMOKE_PORT=18191
    export RALPH_LIVE_SMOKE_READY_TIMEOUT=5
    export RALPH_LIVE_SMOKE_PATHS="/"
    export RALPH_LIVE_SMOKE_FILE="$ARTIFACT_DIR/live-smoke.json"
    : > "$NPM_LOG"
    err=$(verify_runtime)
    eq "live smoke verification passes" "" "$err"
    jq -e '.status=="pass" and .port==18191 and (.probes | any(.path=="/" and .ok==true))' "$RALPH_LIVE_SMOKE_FILE" >/dev/null       && ok "live smoke evidence records passing probe" || bad "live smoke evidence missing/invalid"
    if curl -fsS "http://127.0.0.1:18191/" >/dev/null 2>&1; then
        bad "live smoke server was left running"
    else
        ok "live smoke server is torn down"
    fi
    unset RALPH_LIVE_SMOKE RALPH_LIVE_SMOKE_PORT RALPH_LIVE_SMOKE_READY_TIMEOUT RALPH_LIVE_SMOKE_PATHS RALPH_LIVE_SMOKE_FILE
else
    ok "curl, python3, or jq unavailable; skipped live smoke fixture"
fi

echo "== verify_health_ports rejects unrelated services =="
ss() {
    case "$*" in
        *-ltnp*) printf 'LISTEN 0 511 127.0.0.1:3333 0.0.0.0:* users:(("node",pid=4242,fd=18))\n' ;;
        *-ltn*)  printf 'LISTEN 0 511 127.0.0.1:3333 0.0.0.0:*\n' ;;
    esac
}
readlink() {
    if [[ "$1" == "/proc/4242/cwd" ]]; then
        printf '%s\n' "$TMP/outside"
    else
        command readlink "$@"
    fi
}
curl() { printf '200'; }
export RALPH_HEALTH_PORTS=3333
err=$(verify_health_ports "$TMP/proj")
[[ "$err" == *"no owning process is rooted"* ]] && ok "unrelated port is rejected" || bad "unrelated port passed: $err"

readlink() {
    if [[ "$1" == "/proc/4242/cwd" ]]; then
        printf '%s\n' "$TMP/proj"
    else
        command readlink "$@"
    fi
}
err=$(verify_health_ports "$TMP/proj")
eq "project-owned health port passes" "" "$err"
unset -f ss readlink curl

printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
