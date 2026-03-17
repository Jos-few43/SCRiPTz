#!/usr/bin/env bash
# gemini-research.sh — Run Gemini CLI in headless mode for research tasks
# Called by Claude Code (via Bash tool) to delegate web research to Gemini.
#
# Usage:
#   gemini-research.sh "What are the latest changes in React 19?"
#   gemini-research.sh -m gemini-2.5-pro "Explain the new CSS anchor positioning API"
#   gemini-research.sh --yolo "Summarize this repo's architecture"
#
# Auth: Uses OAuth first, falls back to GEMINI_API_KEY if set.
# Container: Runs inside ai-cli-tools-dev distrobox.

set -euo pipefail

CONTAINER="ai-cli-tools-dev"
TIMEOUT=120
MODEL="gemini-2.5-flash"  # Default to flash for better free-tier quota
YOLO=""
PROMPT=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--model)
            MODEL="$2"
            shift 2
            ;;
        --yolo)
            YOLO="--yolo"
            shift
            ;;
        -t|--timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        *)
            PROMPT="$1"
            shift
            ;;
    esac
done

if [[ -z "$PROMPT" ]]; then
    echo "ERROR: No prompt provided." >&2
    echo "Usage: gemini-research.sh [-m model] [--yolo] \"your question\"" >&2
    exit 1
fi

# Check container is running
if ! distrobox list 2>/dev/null | grep "$CONTAINER" | grep -q "Up"; then
    echo "ERROR: Container '$CONTAINER' is not running. Start it with: distrobox enter $CONTAINER" >&2
    exit 1
fi

# Build gemini command
GEMINI_CMD="gemini"
[[ -n "$MODEL" ]] && GEMINI_CMD="$GEMINI_CMD -m $MODEL"
[[ -n "$YOLO" ]] && GEMINI_CMD="$GEMINI_CMD --yolo"

# Run gemini in headless mode inside the container
# Source profile.d for GEMINI_API_KEY, -p flag runs non-interactively
timeout "$TIMEOUT" distrobox enter "$CONTAINER" -- bash -c "source /etc/profile.d/gemini.sh 2>/dev/null; $GEMINI_CMD -p $(printf '%q' "$PROMPT")" 2>/dev/null
exit_code=$?

if [[ $exit_code -eq 124 ]]; then
    echo "ERROR: Gemini research timed out after ${TIMEOUT}s. Try a more specific prompt or increase timeout with -t." >&2
    exit 1
fi

if [[ $exit_code -eq 41 ]]; then
    echo "ERROR: Gemini auth failed. Re-authenticate by running:" >&2
    echo "  distrobox enter $CONTAINER -- gemini" >&2
    echo "Or set GEMINI_API_KEY in /etc/profile.d/gemini.sh inside the container." >&2
    exit 1
fi

exit $exit_code
