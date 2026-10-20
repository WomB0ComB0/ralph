#!/bin/bash
# The Jules API key must reach curl WITHOUT ever being an argv element of any process:
# argv is readable by every local user through /proc/<pid>/cmdline.
#
# Hermetic: a fake `curl` EXECUTABLE goes first on PATH. It is a real process, so its
# /proc cmdline is the real argv the kernel exposes. It records that argv, every header
# it was handed (literal -H values and the contents of -H @file), every -d body, and
# answers like the Jules REST API. No network, no real Jules.
#
# The fake curl alone cannot see a helper process that has already exited, so two more traps
# catch the key being handed to an EXTERNAL program (e.g. /usr/bin/printf or `env printf`
# writing the header) instead of the printf builtin:
#   - recording `printf`/`echo` stubs go first on PATH. The builtins never reach them, so a stub
#     runs only when something execs an external one, and it logs whether the key was on its argv.
#   - the key canary is longer than the 64 KiB pipe buffer, so an external writer of the
#     -H @fd header (absolute path included) is still blocked mid-write, alive with the key on
#     its argv, when the fake curl scans every process.
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export VERBOSE=false
# shellcheck disable=SC1090
source "$R/lib/utils.sh"
# shellcheck disable=SC1090
source "$R/lib/jules.sh"
set +eu

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (exp [$2] got [$3])"; fi; }

# --- fake curl on PATH --------------------------------------------------------
# Uses only bash builtins to inspect argv, so no helper process ever carries the key.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/curl" <<'FAKE'
#!/usr/bin/env bash
log="${FAKE_CURL_LOG:?}"
args=("$@"); n=${#args[@]}; url="${args[n-1]}"
printf 'CALL\n' >>"$log.argv"
printf 'ARG %s\n' "$@" >>"$log.argv"
# The argv the kernel exposes for THIS process (what another local user would read).
if [[ -r "/proc/$$/cmdline" ]]; then
    printf 'CALL\n' >>"$log.cmdline"
    while IFS= read -r -d '' a; do printf 'CMD %s\n' "$a"; done <"/proc/$$/cmdline" >>"$log.cmdline"
fi
# Every live process's argv while curl runs: the key must be in none of them.
if [[ -n "${FAKE_CURL_NEEDLE:-}" && -d /proc/self ]]; then
    # Wait (bounded) until each -H @file pipe has data first. From then until the header is read
    # below, an external writer of the over-pipe-buffer canary is blocked mid-write, still alive.
    for ((i = 0; i + 1 < n; i++)); do
        [[ "${args[i]}" == -H && "${args[i+1]}" == @* ]] || continue
        exec {w}<"${args[i+1]#@}" || continue
        for ((t = 0; t < 500; t++)); do read -t 0 -u "$w" && break; sleep 0.01; done
        exec {w}<&-
    done
    for f in /proc/[0-9]*/cmdline; do
        c=""
        { while IFS= read -r -d '' a; do c+="$a "; done <"$f"; } 2>/dev/null
        [[ "$c" == *"$FAKE_CURL_NEEDLE"* ]] && printf 'LEAK %s\n' "${f%/cmdline}" >>"$log.leaks"
    done
fi
for ((i = 0; i < n; i++)); do
    case "${args[i]}" in
        -H)
            h="${args[i+1]}"
            if [[ "$h" == @* ]]; then
                while IFS= read -r line || [[ -n "$line" ]]; do printf 'HDR %s\n' "$line"; done <"${h#@}" >>"$log.headers"
            else
                printf 'HDR %s\n' "$h" >>"$log.headers"
            fi ;;
        -d|--data) printf 'DATA %s\n' "${args[i+1]}" >>"$log.data" ;;
    esac
done
[[ "${FAKE_CURL_MODE:-}" == "fail" ]] && { printf 'curl: (22) The requested URL returned error: 403\n' >&2; exit 22; }
case "$url" in
    */sources\?*)    printf '{"sources":[{"name":"sources/github/owner/repo"}]}\n' ;;
    */sessions)      printf '{"name":"sessions/123","state":"QUEUED"}\n' ;;
    */activities\?*) printf '{"activities":[]}\n' ;;
    *)               printf '{"name":"sessions/123","state":"IN_PROGRESS"}\n' ;;
esac
FAKE
chmod +x "$TMP/bin/curl"

# --- recording printf/echo stubs on PATH --------------------------------------
# The builtins always win over PATH, so these run only when something execs an EXTERNAL
# printf/echo (env printf, exec printf, xargs, ...). Each one logs whether the key was
# on its argv, then behaves like the real command.
for helper in printf echo; do
    cat >"$TMP/bin/$helper" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
    if [[ -n "${FAKE_CURL_NEEDLE:-}" && "$a" == *"$FAKE_CURL_NEEDLE"* ]]; then
        builtin printf 'LEAK %s\n' "${0##*/}" >>"${FAKE_CURL_LOG:?}.helpers"
        break
    fi
done
builtin "${0##*/}" "$@"
STUB
    chmod +x "$TMP/bin/$helper"
done
export PATH="$TMP/bin:$PATH"
export FAKE_CURL_LOG="$TMP/curl"

reset_logs() { rm -f "$FAKE_CURL_LOG".*; touch "$FAKE_CURL_LOG".{argv,cmdline,headers,data,leaks,helpers}; }
count() { local n; n=$(grep -cF -- "$2" "$1" 2>/dev/null); printf '%s' "${n:-0}"; }

export JULES_API_BASE="https://jules.test/v1alpha"
# A unique canary with a printf directive in it, so format-string mangling would show. Padded
# past the 64 KiB pipe buffer (and kept under the 128 KiB single-argument limit) so an external
# writer of the header blocks until curl reads it: see the header comment. The leak checks look
# for its unique HEAD: any process holding the key holds the head, and glob-matching the whole
# 96 KiB canary against every process on the host is slow.
NEEDLE_HEAD="canary.%s.$$.${RANDOM}${RANDOM}."
printf -v pad '%098304d' 0   # 96 KiB of zeros, one builtin call
NEEDLE="${NEEDLE_HEAD}${pad}.argv"
export FAKE_CURL_NEEDLE="$NEEDLE_HEAD"
HAVE_PROC=0; [[ -r /proc/self/cmdline ]] && HAVE_PROC=1

assert_no_argv_leak() {   # $1 = label
    eq "$1: key absent from curl's argv" 0 "$(count "$FAKE_CURL_LOG.argv" "$NEEDLE_HEAD")"
    eq "$1: no external printf/echo was handed the key" 0 "$(count "$FAKE_CURL_LOG.helpers" "LEAK")"
    if [[ $HAVE_PROC -eq 1 ]]; then
        eq "$1: key absent from curl's /proc cmdline" 0 "$(count "$FAKE_CURL_LOG.cmdline" "$NEEDLE_HEAD")"
        eq "$1: key absent from every process's cmdline" 0 "$(count "$FAKE_CURL_LOG.leaks" "LEAK")"
    else
        ok "$1: SKIP /proc checks (no procfs)"
    fi
}

echo "== self-check: the traps catch a key handed to an external program =="
# The regression the traps exist for, done on purpose: an external printf writes the header.
# If either trap stopped working, every later "absent" assertion would pass vacuously.
reset_logs
curl -H @<(env printf 'x-goog-api-key: %s\n' "$NEEDLE") "$JULES_API_BASE/sessions/1" >/dev/null 2>&1
eq "external printf stub logged the key on its argv" 1 "$(count "$FAKE_CURL_LOG.helpers" "LEAK printf")"
if [[ $HAVE_PROC -eq 1 ]]; then
    eq "process scan caught the blocked external writer" 1 "$(( $(count "$FAKE_CURL_LOG.leaks" "LEAK") > 0 ))"
else
    ok "self-check: SKIP process scan (no procfs)"
fi

echo "== GET without a body (jules_list_sources) =="
export JULES_API_KEY="$NEEDLE"
reset_logs
out=$(jules_list_sources 2>/dev/null); eq "list sources through the fake curl -> rc 0" 0 "$?"
eq "response body passes through" "sources/github/owner/repo" "$(jq -r '.sources[0].name' <<<"$out")"
eq "key reaches curl as the x-goog-api-key header" 1 "$(count "$FAKE_CURL_LOG.headers" "HDR x-goog-api-key: $NEEDLE")"
eq "Content-Type still sent" 1 "$(count "$FAKE_CURL_LOG.headers" "HDR Content-Type: application/json")"
eq "no request body on a GET" 0 "$(count "$FAKE_CURL_LOG.data" "DATA")"
assert_no_argv_leak "GET"

echo "== POST with a body (jules_create_session) =="
reset_logs
payload=$(jq -cn '{prompt: "argv probe prompt", title: "t"}')
out=$(jules_create_session "$payload" 2>/dev/null); eq "create session -> rc 0" 0 "$?"
eq "response body passes through" "sessions/123" "$(jq -r '.name' <<<"$out")"
eq "request body still reaches curl" 1 "$(count "$FAKE_CURL_LOG.data" '"prompt":"argv probe prompt"')"
eq "-X POST still sent" 1 "$(count "$FAKE_CURL_LOG.argv" "ARG POST")"
eq "key reaches curl on the POST" 1 "$(count "$FAKE_CURL_LOG.headers" "HDR x-goog-api-key: $NEEDLE")"
assert_no_argv_leak "POST"

echo "== every call carries the header (fd re-created per call) =="
reset_logs
jules_get_session "sessions/123" >/dev/null 2>&1; eq "get session -> rc 0" 0 "$?"
jules_list_activities "sessions/123" >/dev/null 2>&1; eq "list activities -> rc 0" 0 "$?"
jules_approve_plan "sessions/123" >/dev/null 2>&1; eq "approve plan -> rc 0" 0 "$?"
eq "3 calls made" 3 "$(count "$FAKE_CURL_LOG.argv" "CALL")"
eq "each call got the x-goog-api-key header" 3 "$(count "$FAKE_CURL_LOG.headers" "HDR x-goog-api-key: $NEEDLE")"
assert_no_argv_leak "sequential calls"

echo "== curl failure still propagates =="
reset_logs
FAKE_CURL_MODE=fail jules_get_session "sessions/123" >/dev/null 2>&1; eq "curl exit code is returned" 22 "$?"
assert_no_argv_leak "failure"

echo "== JULES_API_KEY unset: refuse before calling curl =="
unset JULES_API_KEY
reset_logs
jules_list_sources >/dev/null 2>&1; eq "missing key -> rc 1" 1 "$?"
eq "curl never invoked without a key" 0 "$(count "$FAKE_CURL_LOG.argv" "CALL")"

printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
