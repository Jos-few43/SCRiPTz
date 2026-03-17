#!/usr/bin/env bash
# changelog-update.sh — Append completed action to system changelog + update tech radar
# Usage: changelog-update.sh <action-id>
set -uo pipefail

QUEUE_FILE="${HOME}/shared-memory/core/action-queue.json"
RADAR_SCRIPT="${HOME}/SCRiPTz/tech-radar-update.sh"
VAULT="${VAULT_PATH:-$HOME/Documents/OpenClaw-Vault}"
CHANGELOG="$VAULT/050-runtime/logs/Changelog.md"

log() { echo "[changelog] $*"; }

if [[ -z "${1:-}" ]]; then
  echo "Usage: changelog-update.sh <action-id>"
  exit 1
fi

ACTION_ID="$1"

# Read action details
ACTION=$(jq --arg id "$ACTION_ID" '.actions[] | select(.id == $id)' "$QUEUE_FILE" 2>/dev/null)
if [[ -z "$ACTION" || "$ACTION" == "null" ]]; then
  log "Error: Action $ACTION_ID not found"
  exit 1
fi

COMPONENT=$(echo "$ACTION" | jq -r '.component')
CATEGORY=$(echo "$ACTION" | jq -r '.category')
ACTION_TYPE=$(echo "$ACTION" | jq -r '.action_type')
TITLE=$(echo "$ACTION" | jq -r '.title')
SOURCE=$(echo "$ACTION" | jq -r '.source_report // "N/A"')
STATUS=$(echo "$ACTION" | jq -r '.status')
TODAY=$(date -u +%Y-%m-%d)

log "Recording changelog for $ACTION_ID ($COMPONENT)"

# --- Ensure changelog file exists ---

mkdir -p "$(dirname "$CHANGELOG")"
if [[ ! -f "$CHANGELOG" ]]; then
  cat > "$CHANGELOG" << 'EOF'
---
title: "System Changelog"
type: runtime-log
category: operational
---

# System Changelog

Automated log of actions implemented via the research-to-implementation pipeline.

EOF
  log "Created changelog file"
fi

# --- Append entry ---

# Check if today's date header exists
if ! grep -qF "## $TODAY" "$CHANGELOG"; then
  echo "" >> "$CHANGELOG"
  echo "## $TODAY" >> "$CHANGELOG"
  echo "" >> "$CHANGELOG"
fi

# Build source link
SOURCE_LINK="N/A"
if [[ "$SOURCE" != "N/A" && "$SOURCE" != "" && "$SOURCE" != "null" ]]; then
  local_name=$(basename "$SOURCE" .md)
  SOURCE_LINK="[[${local_name}]]"
fi

# Append entry under today's date
cat >> "$CHANGELOG" << ENTRY
- **${ACTION_TYPE}** \`${COMPONENT}\` (${CATEGORY}) — ${TITLE}
  - Action: ${ACTION_ID} | Status: ${STATUS} | Source: ${SOURCE_LINK}

ENTRY

log "Appended to changelog"

# --- Update tech radar ---

if [[ -f "$RADAR_SCRIPT" ]]; then
  case "$ACTION_TYPE" in
    upgrade)
      bash "$RADAR_SCRIPT" --component "$COMPONENT" --field status --value adopt 2>&1 || true
      ;;
    deprecate)
      bash "$RADAR_SCRIPT" --component "$COMPONENT" --field status --value deprecate 2>&1 || true
      ;;
    remove)
      bash "$RADAR_SCRIPT" --component "$COMPONENT" --field status --value deprecate 2>&1 || true
      ;;
    add)
      bash "$RADAR_SCRIPT" --component "$COMPONENT" --field status --value trial 2>&1 || true
      ;;
    evaluate)
      bash "$RADAR_SCRIPT" --component "$COMPONENT" --field status --value assess 2>&1 || true
      ;;
  esac
  log "Tech radar updated"
fi

# --- Git commit vault changes ---

if [[ -d "$VAULT/.git" ]]; then
  cd "$VAULT"
  git add "050-runtime/logs/Changelog.md" 2>/dev/null || true
  git commit -m "chore(changelog): ${ACTION_TYPE} ${COMPONENT} — ${ACTION_ID}" 2>/dev/null || true
  log "Vault changes committed"
else
  log "Vault is not a git repo — skipping commit"
fi

log "Changelog update complete for $ACTION_ID"
