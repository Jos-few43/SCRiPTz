#!/bin/bash
# Launch Claude Code routed through LiteLLM proxy
# Falls back to direct Anthropic if proxy is down

PROXY_URL="http://localhost:4000"

if curl -sf "${PROXY_URL}/health" > /dev/null 2>&1; then
  echo "Routing through LiteLLM proxy at ${PROXY_URL}"
  ANTHROPIC_BASE_URL="${PROXY_URL}" exec claude "$@"
else
  echo "LiteLLM proxy not available, using direct Anthropic connection"
  exec claude "$@"
fi
