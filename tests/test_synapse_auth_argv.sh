#!/bin/bash
# The Synapse bearer token must reach curl WITHOUT ever being an argv element of any
# process: argv is readable by every local user through /proc/<pid>/cmdline.
#
# Hermetic: a fake `curl` EXECUTABLE goes first on PATH. It is a real process, so its
# /proc cmdline is the real argv the kernel exposes. It records that argv, every header
# it was handed (literal -H values and the contents of -H @file), every --data body, and
# answers like Synapse. No network, no real Synapse.
#
# The fake curl alone cannot see a helper process that has already exited, so two more traps
# catch the token being handed to an EXTERNAL program (e.g. /usr/bin/printf or `env printf`
# writing the header) instead of the printf builtin:
#   - recording `printf`/`echo` stubs go first on PATH. The builtins never reach them, so a stub
#     runs only when something execs an external one, and it logs whether the token was on its argv.
#   - the token canary is longer than the 64 KiB pipe buffer, so an external writer of the
#     -H @fd header (absolute path included) is still blocked mid-write, alive with the token on
#     its argv, when the fake curl scans every process.
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export VERBOSE=false
# shellcheck disable=SC1090
source "$R/lib/utils.sh"
# shellcheck disable=SC1090
source "$R/lib/synapse.sh"
set +eu

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (exp [$2] got [$3])"; fi; }

# --- fake curl on PATH --------------------------------------------------------
# Uses only bash builtins to inspect argv, so no helper process ever carries the token.
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
# Every live process's argv while curl runs: the token must be in none of them.
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
        --data) printf 'DATA %s\n' "${args[i+1]}" >>"$log.data" ;;
    esac
done
[[ "${FAKE_CURL_MODE:-}" == "503" ]] && { printf 'down\n503'; exit 0; }
case "${url##*/}" in
    health)         printf '{"status":"ok"}\n200' ;;
    context.upsert) printf '{"principal_id":"agent:claude","status":"upserted"}\n200' ;;
    context.get)    printf '{"principal_id":"agent:claude","tenant_id":"ralph-dev","active_projects":["livetest"],"updated_at":"2026-10-19T00:00:00Z"}\n200' ;;
    retrieve)       printf '{"results":[],"trace_id":"t-abc"}\n200' ;;
    *)              printf '{}\n200' ;;
esac
FAKE
chmod +x "$TMP/bin/curl"

# --- recording printf/echo stubs on PATH --------------------------------------
# The builtins always win over PATH, so these run only when something execs an EXTERNAL
# printf/echo (env printf, exec printf, xargs, ...). Each one logs whether the token was
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
sleep() { :; }   # instant retry backoff

reset_logs() { rm -f "$FAKE_CURL_LOG".*; touch "$FAKE_CURL_LOG".{argv,cmdline,headers,data,leaks,helpers}; }
count() { local n; n=$(grep -cF -- "$2" "$1" 2>/dev/null); printf '%s' "${n:-0}"; }

export SYNAPSE_URL="http://synapse.test:8080" SYNAPSE_TENANT="ralph-dev" SYNAPSE_RETRIES=2
# A unique canary with a printf directive in it, so format-string mangling would show. Padded
# past the 64 KiB pipe buffer (and kept under the 128 KiB single-argument limit) so an external
# writer of the header blocks until curl reads it: see the header comment. The leak checks look
# for its unique HEAD: any process holding the token holds the head, and glob-matching the whole
# 96 KiB canary against every process on the host is slow.
NEEDLE_HEAD="canary.%s.$$.${RANDOM}${RANDOM}."
printf -v pad '%098304d' 0   # 96 KiB of zeros, one builtin call
NEEDLE="${NEEDLE_HEAD}${pad}.argv"
export FAKE_CURL_NEEDLE="$NEEDLE_HEAD"
HAVE_PROC=0; [[ -r /proc/self/cmdline ]] && HAVE_PROC=1

assert_no_argv_leak() {   # $1 = label
    eq "$1: token absent from curl's argv" 0 "$(count "$FAKE_CURL_LOG.argv" "$NEEDLE_HEAD")"
    eq "$1: no external printf/echo was handed the token" 0 "$(count "$FAKE_CURL_LOG.helpers" "LEAK")"
    if [[ $HAVE_PROC -eq 1 ]]; then
        eq "$1: token absent from curl's /proc cmdline" 0 "$(count "$FAKE_CURL_LOG.cmdline" "$NEEDLE_HEAD")"
        eq "$1: token absent from every process's cmdline" 0 "$(count "$FAKE_CURL_LOG.leaks" "LEAK")"
    else
        ok "$1: SKIP /proc checks (no procfs)"
    fi
}

echo "== self-check: the traps catch a token handed to an external program =="
# The regression the traps exist for, done on purpose: an external printf writes the header.
# If either trap stopped working, every later "absent" assertion would pass vacuously.
reset_logs
curl -H @<(env printf 'Authorization: Bearer %s\n' "$NEEDLE") "$SYNAPSE_URL/health" >/dev/null 2>&1
eq "external printf stub logged the token on its argv" 1 "$(count "$FAKE_CURL_LOG.helpers" "LEAK printf")"
if [[ $HAVE_PROC -eq 1 ]]; then
    eq "process scan caught the blocked external writer" 1 "$(( $(count "$FAKE_CURL_LOG.leaks" "LEAK") > 0 ))"
else
    ok "self-check: SKIP process scan (no procfs)"
fi

echo "== _synapse_call (synapse_ping) with SYNAPSE_TOKEN set =="
export SYNAPSE_TOKEN="$NEEDLE"
reset_logs
synapse_ping >/dev/null 2>&1; eq "ping through the fake curl -> rc 0" 0 "$?"
eq "token reaches curl as the Authorization header" 1 "$(count "$FAKE_CURL_LOG.headers" "HDR Authorization: Bearer $NEEDLE")"
assert_no_argv_leak "ping"
eq "X-Tenant-Id still sent" 1 "$(count "$FAKE_CURL_LOG.headers" "HDR X-Tenant-Id: ralph-dev")"
eq "X-Principal-Id still sent" 1 "$(count "$FAKE_CURL_LOG.headers" "HDR X-Principal-Id: agent:ralph")"

echo "== _synapse_call with a request body (synapse_retrieve) =="
reset_logs
synapse_retrieve "argv probe query" >/dev/null 2>&1; eq "retrieve -> rc 0" 0 "$?"
eq "request body still reaches curl" 1 "$(count "$FAKE_CURL_LOG.data" '"query":"argv probe query"')"
eq "token reaches curl on the retrieve call" 1 "$(count "$FAKE_CURL_LOG.headers" "HDR Authorization: Bearer $NEEDLE")"
assert_no_argv_leak "retrieve"

echo "== every retry attempt carries the header (fd re-created per attempt) =="
reset_logs
FAKE_CURL_MODE=503 _synapse_call GET /health "agent:ralph" >/dev/null 2>&1; eq "503 exhausted -> rc 42" 42 "$?"
eq "1 + SYNAPSE_RETRIES attempts made" 3 "$(count "$FAKE_CURL_LOG.argv" "CALL")"
eq "each attempt got the Authorization header" 3 "$(count "$FAKE_CURL_LOG.headers" "HDR Authorization: Bearer $NEEDLE")"
assert_no_argv_leak "retries"

echo "== synapse_live_test (_syn_lt_step path) =="
reset_logs
out=$(synapse_live_test claude 2>&1); rc=$?
eq "live-test through the fake curl -> rc 0" 0 "$rc"
[[ "$out" == *"[PASS] live-test claude OK"* ]] || bad "live-test output: $out"
calls=$(count "$FAKE_CURL_LOG.argv" "CALL")
eq "live-test made 4 calls" 4 "$calls"
eq "every live-test call got the Authorization header" "$calls" "$(count "$FAKE_CURL_LOG.headers" "HDR Authorization: Bearer $NEEDLE")"
assert_no_argv_leak "live-test"

echo "== pre-built header array never holds the token =="
_syn_headers "agent:ralph"
leaked=0; for h in "${_SYN_HDR[@]}"; do [[ "$h" == *"$NEEDLE"* ]] && leaked=1; done
eq "_SYN_HDR has no bearer element" 0 "$leaked"

echo "== SYNAPSE_TOKEN unset: no Authorization header at all =="
unset SYNAPSE_TOKEN
reset_logs
synapse_ping >/dev/null 2>&1; eq "ping without a token -> rc 0" 0 "$?"
eq "no Authorization header sent" 0 "$(count "$FAKE_CURL_LOG.headers" "Authorization:")"

printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
