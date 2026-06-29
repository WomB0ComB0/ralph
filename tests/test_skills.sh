#!/bin/bash
# TDD harness for guarded skill-authoring (lib/skills.sh), built on the signals layer.
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export VERBOSE=false
# shellcheck disable=SC1090
source "$R/lib/utils.sh"
source "$R/lib/signals.sh"
source "$R/lib/skills.sh"
set +eu

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (exp [$2] got [$3])"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export SIGNAL_DIR="$TMP/signals" SIGNAL_ARCHIVE_DIR="$TMP/signals/.archive" LOG_MD="$TMP/LOG.md"
export SKILL_DIR="$TMP/skills" RUN_ID="r-1-1"

echo "== record_skill: create candidate, update resolution =="
rm -rf "$SKILL_DIR"
k=$(record_skill "validation-failure--cargo-e0432" "cargo check fails E0432" "add mod db; to main.rs" "rust,build")
eq "creates one skill file" 1 "$(find "$SKILL_DIR" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')"
eq "status starts as candidate (guarded)" candidate "$(jq -r .status "$SKILL_DIR/$k.json")"
record_skill "validation-failure--cargo-e0432" "cargo check fails E0432" "add 'mod db;' AND the dep" "rust" >/dev/null
eq "same theme stays one file" 1 "$(find "$SKILL_DIR" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')"
eq "resolution updated" "add 'mod db;' AND the dep" "$(jq -r .resolution "$SKILL_DIR/$k.json")"
jq empty "$SKILL_DIR/$k.json" 2>/dev/null && ok "skill is valid JSON" || bad "invalid JSON"

echo "== approve / reject lifecycle (the guard) =="
approve_skill "$k"; eq "approve -> approved" approved "$(jq -r .status "$SKILL_DIR/$k.json")"
reject_skill "$k";  eq "reject -> rejected"  rejected "$(jq -r .status "$SKILL_DIR/$k.json")"

echo "== recall_skills: ONLY approved skills matching an OPEN signal =="
rm -rf "$SKILL_DIR" "$SIGNAL_DIR"
sk=$(record_signal validation_failure "cargo fails" "error[E0432] in src/main.rs:1" "fix")
record_skill "$sk" "cargo E0432" "add mod db; to main.rs" "rust" >/dev/null
approve_skill "$sk"
sk2=$(record_signal runtime_failure "vet fails" "go vet error here" "fix vet")
record_skill "$sk2" "go vet" "run gofmt first" "go" >/dev/null
record_skill "loop-detected--something-old" "old loop" "do something else" >/dev/null
approve_skill "loop-detected--something-old"
out=$(recall_skills)
[[ "$out" == *"<skills>"* ]] && ok "wrapped in <skills>" || bad "no wrapper"
[[ "$out" == *"add mod db"* ]] && ok "surfaces approved skill for an open signal" || bad "approved+matching skill missing"
[[ "$out" != *"run gofmt first"* ]] && ok "does NOT surface candidate (unapproved) skill" || bad "candidate leaked"
[[ "$out" != *"do something else"* ]] && ok "does NOT surface approved skill with no open signal" || bad "non-matching skill leaked"

echo "== auto-capture: resolving a recurring signal with a note seeds a candidate skill =="
rm -rf "$SKILL_DIR" "$SIGNAL_DIR"
ak=$(record_signal validation_failure "cargo fails" "error[E0099] in src/x.rs:1" "fix")
record_signal validation_failure "cargo fails" "error[E0099] in src/x.rs:7" "fix" >/dev/null
signal_resolve "$ak" "added the missing import"
if [[ -f "$SKILL_DIR/$ak.json" ]]; then
    ok "resolving a freq>=2 signal with a note created a candidate skill"
    eq "skill resolution = the resolve note" "added the missing import" "$(jq -r .resolution "$SKILL_DIR/$ak.json")"
    eq "auto-captured skill is a candidate (still guarded)" candidate "$(jq -r .status "$SKILL_DIR/$ak.json")"
else
    bad "auto-capture did not create a skill"; bad "(resolution)"; bad "(status)"
fi

echo "== auto-resolve synthetic notes are NOT captured as skills =="
rm -rf "$SKILL_DIR" "$SIGNAL_DIR"
bk=$(record_signal validation_failure "x" "evid q here" "fix")
record_signal validation_failure "x" "evid q here2" "fix" >/dev/null
signal_resolve "$bk" "auto-resolved: clean for 2 iterations"
[[ ! -f "$SKILL_DIR/$bk.json" ]] && ok "synthetic auto-resolve note does not author a skill" || bad "synthetic note captured"

echo "== record_skill does not clobber an APPROVED skill's resolution =="
rm -rf "$SKILL_DIR"
record_skill "theme-x" "prob" "the vetted fix" "t" >/dev/null
approve_skill "theme-x"
record_skill "theme-x" "prob" "a worse later note" "t" >/dev/null
eq "approved resolution preserved" "the vetted fix" "$(jq -r .resolution "$SKILL_DIR/theme-x.json")"
eq "still approved" approved "$(jq -r .status "$SKILL_DIR/theme-x.json")"

echo "== signal_resolve preserves _signal_set rc (bad key -> non-zero) =="
signal_resolve "no-such-signal-key" "note" >/dev/null 2>&1 && bad "resolve of missing key returned 0" || ok "resolve of missing key returns non-zero"

printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
