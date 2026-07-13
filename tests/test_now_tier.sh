#!/bin/bash
# TDD harness for the NOW-tier pure helpers in lib/utils.sh
# Sources the lib directly so we don't need the AI CLIs / docker.
# Usage: bash test_now_tier.sh

RALPH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source under test. Disable the EXIT trap noise by running in this shell.
# shellcheck disable=SC1090
source "$RALPH_ROOT/lib/utils.sh"
# shellcheck disable=SC1090
source "$RALPH_ROOT/lib/tools.sh"

PASS=0
FAIL=0
note() { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }

assert_eq() { # desc expected actual
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}
assert_rc() { # desc expected_rc actual_rc
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected rc=$2, got rc=$3)"; fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
note "== retry_with_backoff =="

# 1. success on first try -> rc 0, runs once
: > "$TMP/c1"
retry_with_backoff 3 0 -- bash -c "echo x >> $TMP/c1; true"; rc=$?
assert_rc "success returns 0" 0 "$rc"
assert_eq "success runs exactly once" 1 "$(wc -l < "$TMP/c1" | tr -d ' ')"

# 2. always fails -> nonzero, runs max_attempts times
: > "$TMP/c2"
retry_with_backoff 3 0 -- bash -c "echo x >> $TMP/c2; exit 7"; rc=$?
assert_rc "exhausted retries returns last code" 7 "$rc"
assert_eq "fails max_attempts times" 3 "$(wc -l < "$TMP/c2" | tr -d ' ')"

# 3. flaky: fails twice then succeeds -> rc 0 after 3 attempts
: > "$TMP/c3"
flaky="n=\$(wc -l < $TMP/c3); echo x >> $TMP/c3; [ \"\$n\" -ge 2 ]"
retry_with_backoff 5 0 -- bash -c "$flaky"; rc=$?
assert_rc "flaky eventually succeeds" 0 "$rc"
assert_eq "flaky stops after first success (3 attempts)" 3 "$(wc -l < "$TMP/c3" | tr -d ' ')"

# ---------------------------------------------------------------------------
note "== save_recovery_state / load_recovery_state =="

export STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
export LAZY_STREAK=3 PREVIOUS_LOG_HASH="abc123" NEXT_INSTRUCTION=$'fix the "build"\nand retry'
save_recovery_state 5; rc=$?
assert_rc "save returns 0" 0 "$rc"
if [[ -f "$STATE_DIR/recovery.json" ]] && jq empty "$STATE_DIR/recovery.json" 2>/dev/null; then
    ok "writes valid JSON"
else
    bad "writes valid JSON"
fi
assert_eq "persists iteration" 5 "$(jq -r '.iteration' "$STATE_DIR/recovery.json")"

# clobber the live vars, then restore from disk
export LAZY_STREAK=0 PREVIOUS_LOG_HASH="" NEXT_INSTRUCTION=""
load_recovery_state; rc=$?
assert_rc "load returns 0 when file present" 0 "$rc"
assert_eq "restores LAZY_STREAK" 3 "$LAZY_STREAK"
assert_eq "restores PREVIOUS_LOG_HASH" "abc123" "$PREVIOUS_LOG_HASH"
assert_eq "restores NEXT_INSTRUCTION (special chars)" $'fix the "build"\nand retry' "$NEXT_INSTRUCTION"

# missing file -> rc 1, no crash
export STATE_DIR="$TMP/empty"; mkdir -p "$STATE_DIR"
load_recovery_state; rc=$?
assert_rc "load returns 1 when no file" 1 "$rc"

# ---------------------------------------------------------------------------
note "== scan_for_secrets =="

printf 'hello world\nfoo=bar\ncount = 42\n' > "$TMP/clean.txt"
scan_for_secrets "$TMP/clean.txt" >/dev/null 2>&1; rc=$?
assert_rc "clean file -> rc 1 (no secret)" 1 "$rc"

printf 'aws_key = AKIAIOSFODNN7EXAMPLE\n' > "$TMP/aws.txt"
scan_for_secrets "$TMP/aws.txt" >/dev/null 2>&1; rc=$?
assert_rc "AWS access key id -> rc 0 (found)" 0 "$rc"

printf -- '-----BEGIN RSA PRIVATE KEY-----\nMIIE...\n' > "$TMP/pem.txt"
scan_for_secrets "$TMP/pem.txt" >/dev/null 2>&1; rc=$?
assert_rc "private key block -> rc 0 (found)" 0 "$rc"

printf 'api_key=sk-abcdef0123456789abcdef0123\n' > "$TMP/key.txt"
scan_for_secrets "$TMP/key.txt" >/dev/null 2>&1; rc=$?
assert_rc "long api_key assignment -> rc 0 (found)" 0 "$rc"

# real-world .env shapes (UPPERCASE keys) must NOT scan clean
printf 'AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY\n' > "$TMP/awssec.txt"
scan_for_secrets "$TMP/awssec.txt" >/dev/null 2>&1; rc=$?
assert_rc "uppercase AWS secret key -> rc 0 (found)" 0 "$rc"

printf 'OPENAI_API_KEY=sk-ant-api03-abcdef0123456789abcdef\n' > "$TMP/openai.txt"
scan_for_secrets "$TMP/openai.txt" >/dev/null 2>&1; rc=$?
assert_rc "uppercase OPENAI_API_KEY -> rc 0 (found)" 0 "$rc"

# a genuinely benign config file should still pass clean
printf 'LOG_LEVEL=debug\nPORT=8080\nHOST=localhost\n' > "$TMP/benign.txt"
scan_for_secrets "$TMP/benign.txt" >/dev/null 2>&1; rc=$?
assert_rc "benign config -> rc 1 (clean)" 1 "$rc"


# ---------------------------------------------------------------------------
note "== run_in_sandbox docker arguments =="

grep -q 'util-linux' "$RALPH_ROOT/Dockerfile.ralph" && ok "committed sandbox image provisions flock" || bad "committed sandbox image omits util-linux"
create_default_dockerfile "$TMP/generated.Dockerfile"
grep -q 'util-linux' "$TMP/generated.Dockerfile" && ok "generated sandbox image provisions flock" || bad "generated sandbox image omits util-linux"

SANDBOX_PROJECT="$TMP/project"
mkdir -p "$SANDBOX_PROJECT"
DOCKER_CAPTURE="$TMP/docker-args.txt"

docker() {
    if [[ "${1:-}" == "image" && "${2:-}" == "inspect" ]]; then
        return 0
    fi
    printf '%s\n' "$@" > "$DOCKER_CAPTURE"
    return 0
}

export PROJECT_DIR="$SANDBOX_PROJECT"
unset RALPH_SANDBOX_NETWORK RALPH_SANDBOX_ALLOW_ENV
run_in_sandbox --sandbox --version >/dev/null 2>&1; rc=$?
assert_rc "sandbox wrapper returns docker rc" 0 "$rc"
grep -qxF '/home/ralph/.config:rw,noexec,nosuid,size=256m' "$DOCKER_CAPTURE" && ok "config tmpfs is writable" || bad "config tmpfs missing"
grep -qxF '/home/ralph/.cache:rw,noexec,nosuid,size=1g' "$DOCKER_CAPTURE" && ok "cache tmpfs is writable" || bad "cache tmpfs missing"
grep -qxF '/home/ralph/.bun:rw,nosuid,size=1g' "$DOCKER_CAPTURE" && ok "bun install dir is executable tmpfs" || bad "bun tmpfs missing"
grep -qxF '/home/ralph/.local:rw,nosuid,size=1g' "$DOCKER_CAPTURE" && ok "local install dir is executable tmpfs" || bad "local tmpfs missing"
grep -qxF '/home/ralph/.npm-global:rw,nosuid,size=1g' "$DOCKER_CAPTURE" && ok "npm globals dir is executable tmpfs" || bad "npm-global tmpfs missing"
grep -qxF '/home/ralph/go:rw,nosuid,size=1g' "$DOCKER_CAPTURE" && ok "go bin dir is executable tmpfs" || bad "go tmpfs missing"
grep -qxF 'HOME=/home/ralph' "$DOCKER_CAPTURE" && ok "HOME passed into sandbox" || bad "HOME env missing"
grep -qxF 'XDG_CONFIG_HOME=/home/ralph/.config' "$DOCKER_CAPTURE" && ok "XDG config env passed" || bad "XDG config env missing"
grep -qxF 'BUN_INSTALL=/home/ralph/.bun' "$DOCKER_CAPTURE" && ok "BUN_INSTALL passed" || bad "BUN_INSTALL env missing"
grep -q '^PATH=/home/ralph/.bun/bin:/home/ralph/.local/bin:/home/ralph/.npm-global/bin:/home/ralph/go/bin:' "$DOCKER_CAPTURE" && ok "tool PATH passed" || bad "tool PATH missing"
grep -qxF -- '--no-sandbox' "$DOCKER_CAPTURE" && ok "inner run disables recursive sandbox" || bad "inner --no-sandbox missing"
if grep -qxF -- '--sandbox' "$DOCKER_CAPTURE"; then bad "inner command kept --sandbox"; else ok "inner command strips --sandbox"; fi
unset -f docker

# ---------------------------------------------------------------------------
printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
