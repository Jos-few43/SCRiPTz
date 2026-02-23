#!/usr/bin/env bash
set -euo pipefail

# link-batch-processor.sh — Process queued links with deep AI analysis
# Usage: bash link-batch-processor.sh [max_items]
# Default: process up to 10 items

MAX_ITEMS="${1:-10}"
VAULT="${VAULT_PATH:-$HOME/Documents/OpenClaw-Vault}"
QUEUE_DIR="$VAULT/00-INBOX/link-queue"
TODAY="$(date +%Y-%m-%d)"
LOG_DIR="$VAULT/12-LOGS/claude-code/research"

mkdir -p "$LOG_DIR"

PROCESSED=0
ERRORS=0

log() { echo "[link-processor] $*"; }
log_error() {
  echo "[link-processor] ERROR: $*" >&2
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_DIR/ingest-errors-${TODAY}.log"
}

###############################################################################
# Pre-flight
###############################################################################

if [ ! -d "$QUEUE_DIR" ]; then
  log "No queue directory found: $QUEUE_DIR"
  exit 0
fi

# Collect queue files
mapfile -t QUEUE_FILES < <(find "$QUEUE_DIR" -name '*.json' -type f 2>/dev/null | sort | head -n "$MAX_ITEMS")

if [ ${#QUEUE_FILES[@]} -eq 0 ]; then
  log "Queue is empty — nothing to process"
  exit 0
fi

log "Processing ${#QUEUE_FILES[@]} queued item(s)"

if ! command -v claude &>/dev/null; then
  log_error "claude command not found"
  exit 1
fi

###############################################################################
# Process each item
###############################################################################

for queue_file in "${QUEUE_FILES[@]}"; do
  URL="$(jq -r '.url' "$queue_file")"
  TYPE="$(jq -r '.type' "$queue_file")"
  ACTION="$(jq -r '.action' "$queue_file")"
  SLUG="$(jq -r '.slug' "$queue_file")"
  STUB_PATH="$(jq -r '.stub_path' "$queue_file")"
  VAULT_SUBFOLDER="$(jq -r '.vault_subfolder' "$queue_file")"
  TAGS="$(jq -r '.tags | join(", ")' "$queue_file")"

  log "--- Processing: $URL ($TYPE, $ACTION) ---"

  FULL_STUB="$VAULT/$STUB_PATH"

  # Build the processing prompt
  PROMPT="You are a research assistant processing an ingested URL for an Obsidian knowledge vault.

## URL
${URL}

## Classification
- Type: ${TYPE}
- Action: ${ACTION}
- Tags: ${TAGS}

## Instructions

1. Fetch the content at the URL using WebFetch or WebSearch
2. Create a comprehensive summary note
3. Write the note to: ${FULL_STUB}

The note MUST have this structure:

\`\`\`markdown
---
title: \"[Descriptive title extracted from content]\"
url: \"${URL}\"
type: ingested-link
link_type: \"${TYPE}\"
status: processed
date: ${TODAY}
tags: [${TAGS}]
generated_by: link-batch-processor
related: []
---

# [Title]

**URL:** ${URL}
**Type:** ${TYPE}
**Processed:** ${TODAY}

## Summary
[3-5 sentence summary of the content]

## Key Points
- [Bullet points of main takeaways]

## Relevance
[How this connects to existing vault knowledge]

## Related Notes
[Wikilinks to related vault content: [[path/to/note|Display Name]]]
\`\`\`

If this is an arXiv paper, also extract: authors, abstract, key contributions.
If this is a GitHub repo, also extract: description, key features, installation, tech stack.
If this is a YouTube video, also summarize the key topics discussed.

Write the complete note to the file path above. Overwrite the existing stub."

  # Run claude --print with Sonnet for deep processing
  if ! claude --print \
    --model sonnet \
    --allowedTools "Read,Write,WebFetch,WebSearch,Glob,Grep" \
    "$PROMPT" \
    >> "$LOG_DIR/ingest-output-${TODAY}.log" 2>&1; then
    log_error "claude --print failed for: $URL"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  # Verify the stub was updated
  if [ -f "$FULL_STUB" ]; then
    LINES="$(wc -l < "$FULL_STUB")"
    if [ "$LINES" -lt 10 ]; then
      log_error "Processed stub too short ($LINES lines): $STUB_PATH"
      ERRORS=$((ERRORS + 1))
      continue
    fi
  else
    log_error "Stub not found after processing: $FULL_STUB"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  # If research-worthy, add to TOPICS.md
  if [ "$TYPE" = "paper" ] || [ "$ACTION" = "research" ]; then
    TOPICS_FILE="$VAULT/01-RESEARCH/TOPICS.md"
    if [ -f "$TOPICS_FILE" ]; then
      if ! grep -q "$SLUG" "$TOPICS_FILE" 2>/dev/null; then
        cat >> "$TOPICS_FILE" <<TOPIC_EOF

## [PENDING] ${SLUG}
Priority: P3
Status: Pending
Created: ${TODAY}
Tags: ${TAGS}
Source: link-ingestion (${URL})
Description: Auto-ingested from ${TYPE}. Needs deep research.
TOPIC_EOF
        log "Added to TOPICS.md: $SLUG"
      fi
    fi
  fi

  # Add to Link-Database.md if going to 11-LINKS
  if [ "$VAULT_SUBFOLDER" = "11-LINKS" ]; then
    LINK_DB="$VAULT/11-LINKS/Link-Database.md"
    if [ -f "$LINK_DB" ]; then
      if ! grep -q "$URL" "$LINK_DB" 2>/dev/null; then
        sed -i "/^## Statistics/i | ${SLUG} | ${URL} | Auto-ingested ${TYPE} | ${TAGS} | |" "$LINK_DB" 2>/dev/null || true
        log "Added to Link-Database.md"
      fi
    fi
  fi

  # Notifications
  notify-send "Link Processed" "${TYPE}: ${SLUG}" 2>/dev/null || true
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    curl -s -X POST \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d chat_id="${TELEGRAM_CHAT_ID}" \
      -d text="[link-processor] ${TYPE}: ${SLUG} — ${URL}" \
      >/dev/null 2>&1 || true
  fi

  # Remove from queue
  rm -f "$queue_file"
  PROCESSED=$((PROCESSED + 1))
  log "Completed: $SLUG"
done

###############################################################################
# Git commit
###############################################################################

if cd "$VAULT" && git status --porcelain 2>/dev/null | grep -q .; then
  git add -A
  git commit -m "ingest: processed ${PROCESSED} link(s) — ${TODAY}" 2>&1 || {
    log_error "Git commit failed"
  }
fi

###############################################################################
# Summary
###############################################################################

log "=== Batch Complete ==="
log "  Processed: ${PROCESSED}"
log "  Errors:    ${ERRORS}"

exit 0
