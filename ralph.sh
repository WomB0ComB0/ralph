#!/bin/bash
# Ralph Wiggum - Long-running AI agent loop
# Usage: ./ralph.sh [--tool amp|claude|opencode] [--max-iterations N] [--model MODEL] [--no-archive]

set -euo pipefail

# Source the library modules
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"

# Consolidated Libraries
# shellcheck source=lib/utils.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/utils.sh"
# shellcheck source=lib/engine.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/engine.sh"
# shellcheck source=lib/tools.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/tools.sh"

# Check dependencies before running
check_dependencies || exit 1

# Run main function
main "$@"