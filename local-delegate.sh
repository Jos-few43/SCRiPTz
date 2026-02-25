#!/usr/bin/env bash
# local-delegate.sh — Wrapper for local-agent.py
# Called by OpenClaw main to delegate tasks to the local Ollama agent.
#
# Usage:
#   local-delegate.sh "List files in ~/PROJECTz/"
#   local-delegate.sh -m mistral-nemo:latest "Check disk usage"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT="${SCRIPT_DIR}/local-agent.py"
TIMEOUT=120

# Check that local-agent.py exists
if [[ ! -f "$AGENT" ]]; then
    echo "ERROR: local-agent.py not found at $AGENT" >&2
    exit 1
fi

# Check Ollama is reachable
if ! curl -sf --max-time 3 http://localhost:11434/api/tags > /dev/null 2>&1; then
    echo "ERROR: Ollama is not running at localhost:11434. Start it first."
    exit 1
fi

# Run the agent with a timeout, capturing only stdout (stderr has tool traces)
timeout "$TIMEOUT" python3 "$AGENT" "$@" 2>/dev/null
exit_code=$?

if [[ $exit_code -eq 124 ]]; then
    echo "ERROR: Local agent timed out after ${TIMEOUT}s. The task may be too complex for a single invocation."
    exit 1
fi

exit $exit_code
