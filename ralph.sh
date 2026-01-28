#!/bin/bash
# Ralph Wiggum - Long-running AI agent loop
# Usage: ./ralph.sh [--tool amp|claude|opencode] [--max-iterations N] [--model MODEL] [--no-archive]

set -euo pipefail

# Source the library
# Source the library modules
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
  DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE" # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
SCRIPT_DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
# shellcheck source=./lib/core.sh
source "$SCRIPT_DIR/lib/core.sh"
# shellcheck source=./lib/dependencies.sh
source "$SCRIPT_DIR/lib/dependencies.sh"
# shellcheck source=./lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=./lib/git.sh
source "$SCRIPT_DIR/lib/git.sh"
# shellcheck source=./lib/ai.sh
source "$SCRIPT_DIR/lib/ai.sh"
# shellcheck source=./lib/artifacts.sh
source "$SCRIPT_DIR/lib/artifacts.sh"
# shellcheck source=./lib/sandbox.sh
source "$SCRIPT_DIR/lib/sandbox.sh"
# shellcheck source=./lib/main_loop.sh
source "$SCRIPT_DIR/lib/main_loop.sh"
# shellcheck source=./lib/testing.sh
source "$SCRIPT_DIR/lib/testing.sh"
# shellcheck source=./lib/swarm.sh
source "$SCRIPT_DIR/lib/swarm.sh"
# shellcheck source=./lib/copilot.sh
source "$SCRIPT_DIR/lib/copilot.sh"

# Run main function
main "$@"
