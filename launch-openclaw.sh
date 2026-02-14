#!/usr/bin/env bash
set -euo pipefail

echo "🦅 Launching OpenClaw in containerized environment..."
echo ""

# Enter the OpenClaw container
distrobox enter openclaw-dev -- openclaw "$@"
