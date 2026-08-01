#!/bin/bash
# TDD harness for the loop-reliability guards (lib/engine.sh):
#   stall_limit_reached  — no-progress ceiling (stall abort)
#   run_budget_exceeded  — aggregate token / wall-clock FinOps ceiling
#   backlog_exit_allowed  — backlog-drain cannot bypass completion gates
# Pure functions, so this suite is hermetic (no sandbox state needed).
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export VERBOSE=false
# shellcheck disable=SC1090
source "$R/lib/utils.sh"
# shellcheck disable=SC1090
source "$R/lib/engine.sh"
set +eu

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }
# yes DESC CMD... -> expect CMD to succeed (return 0); no DESC CMD... -> expect failure.
yes() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
no()  { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "== stall_limit_reached STREAK CEILING =="
no  "ceiling 0 disables the stall abort (never trips)"      stall_limit_reached 99 0
no  "streak below ceiling does not trip"                    stall_limit_reached 4 5
yes "streak equal to ceiling trips"                         stall_limit_reached 5 5
yes "streak above ceiling trips"                            stall_limit_reached 7 5
no  "non-numeric streak is safe (no trip)"                  stall_limit_reached x 5
no  "non-numeric ceiling is safe (no trip)"                 stall_limit_reached 5 y

echo "== run_budget_exceeded TOK TOK_MAX ELAPSED SEC_MAX =="
no  "all ceilings 0 -> unlimited (never trips)"             run_budget_exceeded 100000 0 100000 0
no  "tokens below ceiling ok"                               run_budget_exceeded 50 100 0 0
yes "tokens at ceiling trips"                               run_budget_exceeded 100 100 0 0
yes "tokens over ceiling trips"                             run_budget_exceeded 150 100 0 0
no  "time below ceiling ok"                                 run_budget_exceeded 0 0 59 60
yes "time at ceiling trips"                                 run_budget_exceeded 0 0 60 60
no  "non-numeric inputs are safe (no trip)"                 run_budget_exceeded x y z w

# The echoed reason should name which ceiling fired, and tokens take precedence.
r=$(run_budget_exceeded 100 100 0 0);   case "$r" in *token*) ok "reason names the token ceiling";; *) bad "reason names the token ceiling (got [$r])";; esac
r=$(run_budget_exceeded 0 0 60 60);     case "$r" in *time*)  ok "reason names the time ceiling";;  *) bad "reason names the time ceiling (got [$r])";; esac
r=$(run_budget_exceeded 100 100 999 1); case "$r" in *token*) ok "token ceiling checked before time";; *) bad "token ceiling checked before time (got [$r])";; esac


echo "== backlog_exit_allowed VERIFY_OK QUEUED_CORRECTION =="
export RALPH_REQUIRE_VERIFY_ON_COMPLETE=1
export RALPH_REQUIRE_QUALITY_ON_COMPLETE=0
yes "clean verification and no correction allow backlog exit"        backlog_exit_allowed true ""
no  "failed verification blocks backlog exit"                        backlog_exit_allowed false ""
no  "queued correction blocks backlog exit"                          backlog_exit_allowed true "fix runtime first"
export RALPH_REQUIRE_VERIFY_ON_COMPLETE=0
yes "disabled verify gate allows failed verification only when clean" backlog_exit_allowed false ""
no  "queued correction still blocks when verify gate disabled"        backlog_exit_allowed false "fix runtime first"

export RALPH_REQUIRE_VERIFY_ON_COMPLETE=1
export RALPH_REQUIRE_QUALITY_ON_COMPLETE=1
export QUALITY_FILE="$TMP/QUALITY.md"
printf 'Quality Gate: continue
' > "$QUALITY_FILE"
no  "quality gate continue blocks backlog exit"                      backlog_exit_allowed true ""
printf 'Quality Gate: pass
' > "$QUALITY_FILE"
yes "quality gate pass allows clean backlog exit"                    backlog_exit_allowed true ""

printf '\n== TOTAL: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
