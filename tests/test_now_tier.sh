#!/bin/bash
# TDD harness for the NOW-tier pure helpers in lib/utils.sh
# Sources the lib directly so we don't need the AI CLIs / docker.
# Usage: bash test_now_tier.sh

RALPH_ROOT="/home/wombocombo/github/dev/ralph"

# Source under test. Disable the EXIT trap noise by running in this shell.
# shellcheck disable=SC1090
source "$RALPH_ROOT/lib/utils.sh"

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
printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
