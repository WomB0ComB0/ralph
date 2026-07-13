#!/bin/bash
# Ralph Wiggum - Long-running AI agent loop
# Usage: ./ralph.sh [--tool opencode|claude|amp|agy|codex|jules] [--max-iterations N] [--model MODEL] [--no-archive]

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
# shellcheck source=lib/processes.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/processes.sh"
# shellcheck source=lib/run_manifest.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/run_manifest.sh"
# shellcheck source=lib/engine.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/engine.sh"
# shellcheck source=lib/tools.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/tools.sh"
# shellcheck source=lib/signals.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/signals.sh"
# shellcheck source=lib/skills.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/skills.sh"
# shellcheck source=lib/lint.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/lint.sh"
# shellcheck source=lib/triage.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/triage.sh"
# shellcheck source=lib/jules.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/jules.sh"
# shellcheck source=lib/synapse.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/synapse.sh"

# NOTE: dependency checking is deferred to main() — it runs only on the iterating path
# (after --tool/config are parsed) so `--help`, `--version`, `--test`, and the read-only
# signal/skill/lint/swarm/copilot subcommands work on hosts without the full toolchain,
# and the AI-tool check sees the actual selected tool rather than always defaulting to opencode.

# Run main function
main "$@"