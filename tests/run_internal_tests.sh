#!/bin/bash
# Runs Ralph's own run_internal_tests by sourcing the libs directly,
# bypassing ralph.sh's check_dependencies (which would try to auto-install tools).
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export VERBOSE=false
# shellcheck disable=SC1090
source "$R/lib/utils.sh"
source "$R/lib/engine.sh"
source "$R/lib/tools.sh"
source "$R/lib/signals.sh"
source "$R/lib/skills.sh"
source "$R/lib/lint.sh"
source "$R/lib/triage.sh"
source "$R/lib/mine.sh"
run_internal_tests
