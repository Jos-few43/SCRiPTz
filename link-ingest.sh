#!/usr/bin/env bash
set -euo pipefail

# link-ingest.sh — Classify a URL, create inbox stub, queue for processing
# Usage: bash link-ingest.sh <url> [source]
# source: "telegram", "cli" (default: "cli")

URL="${1:?Usage: link-ingest.sh <url> [source]}"
SOURCE="${2:-cli}"
VAULT="${VAULT_PATH:-$HOME/Documents/OpenClaw-Vault}"
CLASSIFIER="$HOME/SCRiPTz/link-classifier.sh"
TODAY="$(date +%Y-%m-%d)"

###############################################################################
# Classify
###############################################################################

if [ ! -f "$CLASSIFIER" ]; then
  echo "ERROR: Classifier not found: $CLASSIFIER" >&2
  exit 1
fi

CLASSIFICATION="$(bash "$CLASSIFIER" "$URL" "$SOURCE")"
TYPE="$(echo "$CLASSIFICATION" | jq -r '.type')"
ACTION="$(echo "$CLASSIFICATION" | jq -r '.action')"
SLUG="$(echo "$CLASSIFICATION" | jq -r '.slug')"
STUB_PATH="$(echo "$CLASSIFICATION" | jq -r '.stub_path')"
QUEUE_FILE="$(echo "$CLASSIFICATION" | jq -r '.queue_file')"
TAGS="$(echo "$CLASSIFICATION" | jq -r '.tags | join(", ")')"

###############################################################################
# Create inbox stub
###############################################################################

FULL_STUB_PATH="$VAULT/$STUB_PATH"
mkdir -p "$(dirname "$FULL_STUB_PATH")"

# Don't overwrite existing stubs
if [ -f "$FULL_STUB_PATH" ]; then
  echo "Stub already exists: $STUB_PATH"
  echo "$CLASSIFICATION"
  exit 0
fi

cat > "$FULL_STUB_PATH" <<STUB_EOF
---
title: "${SLUG}"
url: "${URL}"
type: ingested-link
link_type: "${TYPE}"
action: "${ACTION}"
source: "${SOURCE}"
status: queued
date: ${TODAY}
tags: [${TAGS}]
generated_by: link-ingest
---

# ${SLUG}

**URL:** ${URL}
**Type:** ${TYPE}
**Action:** ${ACTION}
**Queued:** ${TODAY}
**Source:** ${SOURCE}

---

*Pending deep processing. Summary will be added by batch processor.*
STUB_EOF

###############################################################################
# Queue for deep processing
###############################################################################

QUEUE_DIR="$VAULT/00-INBOX/link-queue"
mkdir -p "$QUEUE_DIR"

echo "$CLASSIFICATION" > "$QUEUE_DIR/$QUEUE_FILE"

###############################################################################
# Output
###############################################################################

echo "Ingested: $URL"
echo "  Type: $TYPE | Action: $ACTION"
echo "  Stub: $STUB_PATH"
echo "  Queue: $QUEUE_FILE"
echo "$CLASSIFICATION"
