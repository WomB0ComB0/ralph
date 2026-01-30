#!/bin/bash
# Ralph Benchmark Helper
# Usage: ./benchmark.sh [MAX_ITERATIONS]

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
MAX_ITER="${1:-5}"

METRICS_FILE="$SCRIPT_DIR/.ralph/state/metrics.json"
REPORT_FILE="$SCRIPT_DIR/benchmark_report.md"

echo "=== Starting Ralph Benchmark ==="
echo "Scenario: 5 iterations on current project"

# Clean up previous metrics
if [[ -f "$METRICS_FILE" ]]; then
    mv "$METRICS_FILE" "${METRICS_FILE}.bak"
    echo "Backed up existing metrics to ${METRICS_FILE}.bak"
fi

# Run Ralph in a non-interactive mode for benchmarking
# We expect AGENTS.md to exist
if [[ ! -f "$SCRIPT_DIR/AGENTS.md" ]]; then
    echo "Creating a dummy AGENTS.md for benchmark..."
    echo "Self-benchmarking: analyze the codebase and suggest one small improvement in a comment." > "$SCRIPT_DIR/AGENTS.md"
fi

echo "Running Ralph..."
./ralph.sh --max-iterations "$MAX_ITER" --no-archive

echo -e "\n=== Benchmarking Complete ==="
echo "Analyzing results..."

if [[ -f "$METRICS_FILE" ]]; then
    python3 "$SCRIPT_DIR/benchmark_analyzer.py" --input "$METRICS_FILE" --output "$REPORT_FILE"
    echo "Benchmark report generated at: $REPORT_FILE"
else
    echo "Error: No metrics file found at $METRICS_FILE"
    exit 1
fi
