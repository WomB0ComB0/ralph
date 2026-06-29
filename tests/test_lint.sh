#!/bin/bash
# TDD harness for the knowledge-lint curator pass (lib/lint.sh).
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export VERBOSE=false
# shellcheck disable=SC1090
source "$R/lib/utils.sh"
source "$R/lib/signals.sh"
source "$R/lib/skills.sh"
source "$R/lib/lint.sh"
set +eu

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (exp [$2] got [$3])"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export SIGNAL_DIR="$TMP/signals" SKILL_DIR="$TMP/skills" RUN_ID="r-1-1"
export RALPH_LINT_MIN_FREQ=2 RALPH_LINT_STALE_DAYS=30
init_signals; init_skills

# 1. GAP: recurring open signal (freq 2), no skill
gap=$(record_signal validation_failure "cargo fails" "GAP recurring problem" "fix")
record_signal validation_failure "cargo fails" "GAP recurring problem" "fix" >/dev/null

# 2. COVERED: recurring open + approved skill, recent -> neither gap nor stale
cov=$(record_signal runtime_failure "vet fails" "COVERED recurring" "fix")
record_signal runtime_failure "vet fails" "COVERED recurring" "fix" >/dev/null
record_skill "$cov" "vet" "run gofmt" >/dev/null; approve_skill "$cov"

# 3. STALE: approved skill whose signal has been idle far past TTL
stale=$(RALPH_NOW=2020-01-01T00:00:00Z record_signal lazy_streak "idle" "STALE old problem" "fix")
RALPH_NOW=2020-01-01T00:00:00Z record_signal lazy_streak "idle" "STALE old problem" "fix" >/dev/null
record_skill "$stale" "idle" "do work" >/dev/null; approve_skill "$stale"

# 4. ORPHAN: approved skill with no matching signal
record_skill "orphan-theme-zzz" "p" "r" >/dev/null; approve_skill "orphan-theme-zzz"

# 5. BACKLOG: candidate skill (with a signal, so not also orphan)
bk=$(record_signal loop_detected "loop" "BACKLOG candidate" "fix")
record_skill "$bk" "loop" "x" >/dev/null   # left candidate

# 6. HIGH-SEV: open high-severity signal, freq 1 (below min_freq -> not a gap)
hot=$(record_signal runtime_failure "crash" "HOT severe" "fix" "" high)

# 7. LOW-FREQ negative: open freq 1, no skill -> must NOT be a gap
low=$(record_signal validation_failure "lint" "LOW once" "fix")

# 8. REJECTED: recurring open signal whose only skill was REJECTED -> still a gap
rej=$(record_signal validation_failure "fmt" "REJECTED still broken" "fix")
record_signal validation_failure "fmt" "REJECTED still broken" "fix" >/dev/null
record_skill "$rej" "fmt" "bad fix" >/dev/null; reject_skill "$rej"

out=$(lint_knowledge)
sect() { printf '%s\n' "$out" | awk -v t="$1" 'index($0,t){f=1;next} /^== /{f=0} f'; }

echo "== exact summary counts =="
summary=$(printf '%s\n' "$out" | grep '^lint summary:')
eq "summary line" "lint summary: 2 gaps, 1 orphaned, 1 stale, 1 backlog, 1 high-severity" "$summary"

echo "== category membership =="
g=$(sect "KNOWLEDGE GAPS")
printf '%s' "$g" | grep -qF "$gap" && ok "gap signal listed under KNOWLEDGE GAPS" || bad "gap missing from gaps"
printf '%s' "$g" | grep -qF "$cov"  && bad "covered theme leaked into gaps" || ok "covered theme not a gap"
printf '%s' "$g" | grep -qF "$low"  && bad "low-freq theme leaked into gaps" || ok "low-freq (freq<min) not a gap"
printf '%s' "$g" | grep -qF "$rej"  && ok "rejected-skill theme still flagged a gap" || bad "rejected skill wrongly suppressed the gap"
printf '%s' "$(sect "ORPHANED SKILLS")" | grep -qF "orphan-theme-zzz" && ok "orphan skill listed" || bad "orphan missing"
printf '%s' "$(sect "STALE APPROVED")" | grep -qF "$stale" && ok "stale skill listed" || bad "stale missing"
printf '%s' "$(sect "STALE APPROVED")" | grep -qF "$cov" && bad "recent covered skill flagged stale" || ok "recent skill not stale"
printf '%s' "$(sect "APPROVAL BACKLOG")" | grep -qF "$bk" && ok "candidate listed in backlog" || bad "backlog missing"
printf '%s' "$(sect "UNRESOLVED HIGH-SEVERITY")" | grep -qF "$hot" && ok "high-sev signal listed" || bad "high-sev missing"

echo "== quiet mode: summary only, no sections =="
q=$(lint_knowledge quiet)
printf '%s' "$q" | grep -q '^lint summary:' && ok "quiet prints summary" || bad "quiet missing summary"
printf '%s' "$q" | grep -q 'KNOWLEDGE GAPS' && bad "quiet leaked sections" || ok "quiet omits sections"

echo "== empty store is a clean no-op =="
export SIGNAL_DIR="$TMP/empty_s" SKILL_DIR="$TMP/empty_k"; init_signals; init_skills
e=$(lint_knowledge)
eq "empty summary all zero" "lint summary: 0 gaps, 0 orphaned, 0 stale, 0 backlog, 0 high-severity" "$(printf '%s\n' "$e" | grep '^lint summary:')"

printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
