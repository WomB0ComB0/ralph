#!/bin/bash
# Run every Ralph test suite: the 6 unit harnesses + the native `ralph --test`.
# Each suite sources lib/*.sh directly and uses its own mktemp sandboxes, so this
# is hermetic and safe to run anywhere. Exit 0 iff every suite passes.
#
# Usage: ./tests/run_all.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0

run() {
    local name="$1" script="$2" out tmpd
    tmpd=$(mktemp -d)
    # Run in a throwaway cwd so no suite can write into the repo.
    out=$(cd "$tmpd" && bash "$script" 2>&1)
    rm -rf "$tmpd"
    if printf '%s\n' "$out" | grep -qE 'TOTAL: [0-9]+ passed, 0 failed|Test Summary: [0-9]+ passed, 0 failed'; then
        printf '  PASS  %-9s %s\n' "$name" "$(printf '%s\n' "$out" | grep -oE 'TOTAL: [0-9]+ passed.*|Test Summary: [0-9]+ passed.*' | head -1)"
    else
        printf '  FAIL  %-9s\n' "$name"
        printf '%s\n' "$out" | grep -iE 'fail' | head -8
        fail=1
    fi
}

echo "Ralph test suites:"
run now      "$DIR/test_now_tier.sh"
run next     "$DIR/test_next_tier.sh"
run lists    "$DIR/test_lists.sh"
run signals  "$DIR/test_signals.sh"
run skills   "$DIR/test_skills.sh"
run swarm    "$DIR/test_swarm.sh"
run native   "$DIR/run_internal_tests.sh"

echo
if [[ $fail -eq 0 ]]; then
    echo "All suites passed."
else
    echo "Some suites FAILED."
fi
exit $fail
