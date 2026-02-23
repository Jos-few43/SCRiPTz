#!/usr/bin/env bash
set -euo pipefail

# telegram-ingest-handler.sh — Handle incoming Telegram messages with URLs
# Usage: bash telegram-ingest-handler.sh <url> [chat_id]
# Called by OpenClaw's Telegram bot when a message contains a URL

URL="${1:?Usage: telegram-ingest-handler.sh <url> [chat_id]}"
CHAT_ID="${2:-${TELEGRAM_CHAT_ID:-}}"
INGEST="$HOME/SCRiPTz/link-ingest.sh"

###############################################################################
# Ingest the URL
###############################################################################

RESULT="$(bash "$INGEST" "$URL" "telegram" 2>&1)" || {
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "$CHAT_ID" ]; then
    curl -s -X POST \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d chat_id="$CHAT_ID" \
      -d text="Failed to ingest: ${URL}" \
      >/dev/null 2>&1 || true
  fi
  exit 1
}

###############################################################################
# Extract classification for reply
###############################################################################

# Last line of RESULT is the JSON classification
JSON_LINE="$(echo "$RESULT" | tail -1)"
TYPE="$(echo "$JSON_LINE" | jq -r '.type' 2>/dev/null || echo "unknown")"
ACTION="$(echo "$JSON_LINE" | jq -r '.action' 2>/dev/null || echo "queued")"

###############################################################################
# Reply to Telegram
###############################################################################

if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "$CHAT_ID" ]; then
  REPLY="Classified as *${TYPE}* → ${ACTION}
Queued for deep processing."

  curl -s -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="$CHAT_ID" \
    -d text="$REPLY" \
    -d parse_mode="Markdown" \
    >/dev/null 2>&1 || true
fi

echo "$RESULT"
