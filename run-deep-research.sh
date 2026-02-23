#!/usr/bin/env bash
set -euo pipefail

# run-deep-research.sh — Orchestration layer for the deep research pipeline
# Called by n8n or manually.
#
# Usage:
#   bash run-deep-research.sh [max_topics]
#   Default: 3 topics per run

###############################################################################
# Configuration
###############################################################################

MAX_TOPICS="${1:-3}"
VAULT="${VAULT_PATH:-$HOME/Documents/OpenClaw-Vault}"
SCANNER="$HOME/SCRiPTz/vault-gap-scanner.sh"
POSTPROCESS="$HOME/SCRiPTz/vault-research-postprocess.sh"
TODAY="$(date +%Y-%m-%d)"
LOG_DIR="$VAULT/12-LOGS/claude-code/research"
ERROR_LOG="$LOG_DIR/errors-${TODAY}.log"

COUNTERS_DIR="$(mktemp -d)"
trap 'rm -rf "$COUNTERS_DIR"' EXIT
echo 0 > "$COUNTERS_DIR/success"
echo 0 > "$COUNTERS_DIR/errors"

###############################################################################
# Helpers
###############################################################################

log() {
  echo "[research-runner] $*"
}

log_error() {
  echo "[research-runner] ERROR: $*" >&2
  mkdir -p "$LOG_DIR"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$ERROR_LOG"
}

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//'
}

notify_desktop() {
  local topic="$1"
  notify-send "Deep Research Complete" "${topic} — saved to vault" 2>/dev/null || true
}

notify_telegram() {
  local topic="$1"
  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
    curl -s -X POST \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d chat_id="${TELEGRAM_CHAT_ID}" \
      -d text="[research-runner] Completed: ${topic}" \
      -d parse_mode="Markdown" \
      >/dev/null 2>&1 || true
  fi
}

###############################################################################
# Pre-flight checks
###############################################################################

mkdir -p "$LOG_DIR"

if [[ ! -d "$VAULT" ]]; then
  log_error "Vault directory not found: $VAULT"
  exit 0
fi

if [[ ! -f "$SCANNER" ]]; then
  log_error "Gap scanner not found: $SCANNER"
  exit 0
fi

if ! command -v claude &>/dev/null; then
  log_error "claude command not found — cannot run research pipeline"
  exit 0
fi

if ! command -v jq &>/dev/null; then
  log_error "jq command not found — required for JSON processing"
  exit 0
fi

###############################################################################
# Phase 1: Scan for gaps
###############################################################################

log "Scanning vault for knowledge gaps..."

GAPS_JSON="$(bash "$SCANNER" 2>/dev/null)" || {
  log_error "Gap scanner failed"
  exit 0
}

# Check for empty output
if [[ -z "$GAPS_JSON" || "$GAPS_JSON" == "[]" ]]; then
  log "No gaps found — vault is up to date"
  exit 0
fi

TOTAL_GAPS="$(echo "$GAPS_JSON" | jq 'length')"
log "Found ${TOTAL_GAPS} gap(s), processing top ${MAX_TOPICS}"

###############################################################################
# Phase 2: Process each topic
###############################################################################

while IFS= read -r gap; do
  # Extract fields
  TOPIC="$(echo "$gap" | jq -r '.topic')"
  GAP_TYPE="$(echo "$gap" | jq -r '.gap_type')"
  PRIORITY="$(echo "$gap" | jq -r '.priority')"
  SUBFOLDER="$(echo "$gap" | jq -r '.suggested_subfolder')"
  SOURCE_FILE="$(echo "$gap" | jq -r '.source_file')"
  RELATED_FILES="$(echo "$gap" | jq -r '.related_files | join(", ")')"
  CONTEXT="$(echo "$gap" | jq -r '.context')"

  SLUG="$(slugify "$TOPIC")"
  REPORT_DIR="$VAULT/01-RESEARCH/${SUBFOLDER}"
  REPORT_PATH="${REPORT_DIR}/${SLUG}.md"

  log "--- Processing: ${TOPIC} (${PRIORITY}, ${GAP_TYPE}) ---"

  # Skip if report already exists and has content
  if [[ -f "$REPORT_PATH" ]]; then
    existing_lines="$(wc -l < "$REPORT_PATH")"
    if (( existing_lines > 10 )); then
      log "Report already exists with ${existing_lines} lines — skipping: ${REPORT_PATH}"
      continue
    fi
  fi

  # Ensure subfolder exists
  mkdir -p "$REPORT_DIR"

  # Build related files context for the prompt
  RELATED_CONTEXT=""
  if [[ -n "$SOURCE_FILE" && "$SOURCE_FILE" != "null" ]]; then
    SOURCE_FULL="$VAULT/$SOURCE_FILE"
    if [[ -f "$SOURCE_FULL" ]]; then
      RELATED_CONTEXT="$(cat "$SOURCE_FULL" 2>/dev/null | head -50)" || true
    fi
  fi

  # Construct the research prompt
  PROMPT="$(cat <<PROMPT_EOF
You are a deep research agent generating a comprehensive report for an Obsidian knowledge vault.

## Topic
**${TOPIC}**

## Metadata
- Priority: ${PRIORITY}
- Gap type: ${GAP_TYPE}
- Context: ${CONTEXT}
- Source file: ${SOURCE_FILE}
- Related files: ${RELATED_FILES}

## Related vault content (first 50 lines of source)
\`\`\`
${RELATED_CONTEXT}
\`\`\`

## Output
Write the report to: ${REPORT_PATH}

## Format — 8-Section Structure
The report MUST follow this exact structure:

## 1. Executive Summary
A 3-5 sentence overview of the topic and key findings.

## 2. Core Concepts
Detailed explanation of fundamental concepts with definitions.

## 3. Architecture / How It Works
Technical deep-dive into mechanisms, architectures, or processes.

## 4. Practical Applications
Real-world use cases, examples, and implementation patterns.

## 5. Trade-offs & Limitations
Honest assessment of drawbacks, constraints, and edge cases.

## 6. Comparison with Alternatives
How this compares to competing approaches or related concepts.

## 7. Open Questions & Follow-ups
Unanswered questions and topics for further research. Use [[wikilink]] format for potential follow-up topics.

## 8. Sources & References
List of sources consulted. Use web search to find current, authoritative sources.

## Quality Requirements
- Use [[wikilinks]] to reference related vault topics where appropriate
- Include a YAML frontmatter block with: title, date (${TODAY}), type (research), status (complete), tags, generated_by (claude-deep-research)
- Minimum 200 lines of substantive content
- Use Obsidian-compatible Markdown
- Search the web for up-to-date information on this topic
- Read any related vault files to maintain consistency with existing knowledge

Write the complete report to the file path specified above.
PROMPT_EOF
)"

  # Run claude --print
  log "Running claude research for: ${TOPIC}"
  if ! claude --print \
    --model sonnet \
    --allowedTools "Bash,Read,Write,Glob,Grep,WebSearch,WebFetch" \
    "$PROMPT" \
    >> "$LOG_DIR/claude-output-${TODAY}.log" 2>&1; then
    log_error "claude --print failed for topic: ${TOPIC}"
    echo $(( $(cat "$COUNTERS_DIR/errors") + 1 )) > "$COUNTERS_DIR/errors"
    continue
  fi

  # Validate report
  if [[ ! -f "$REPORT_PATH" ]]; then
    log_error "Report file was not created: ${REPORT_PATH}"
    echo $(( $(cat "$COUNTERS_DIR/errors") + 1 )) > "$COUNTERS_DIR/errors"
    continue
  fi

  REPORT_LINES="$(wc -l < "$REPORT_PATH")"
  if (( REPORT_LINES < 10 )); then
    log_error "Report too short (${REPORT_LINES} lines): ${REPORT_PATH}"
    echo $(( $(cat "$COUNTERS_DIR/errors") + 1 )) > "$COUNTERS_DIR/errors"
    continue
  fi

  log "Report generated: ${REPORT_PATH} (${REPORT_LINES} lines)"

  # Post-process: integrate into vault knowledge graph
  log "Running post-processor..."
  if ! bash "$POSTPROCESS" "$REPORT_PATH" "$SUBFOLDER" "$TOPIC" "$TODAY" 2>&1; then
    log_error "Post-processor failed for: ${TOPIC}"
    # Non-fatal — report was still written
  fi

  # Notifications
  notify_desktop "$TOPIC"
  notify_telegram "$TOPIC"

  echo $(( $(cat "$COUNTERS_DIR/success") + 1 )) > "$COUNTERS_DIR/success"
  log "Completed: ${TOPIC}"

done < <(echo "$GAPS_JSON" | jq -c ".[0:${MAX_TOPICS}][]")

###############################################################################
# Phase 3: Git commit vault changes
###############################################################################

SUCCESS_COUNT="$(cat "$COUNTERS_DIR/success")"
ERROR_COUNT="$(cat "$COUNTERS_DIR/errors")"

log "Checking for vault changes to commit..."

if cd "$VAULT" && git status --porcelain 2>/dev/null | grep -q .; then
  git add -A
  git commit -m "research: auto-generated ${SUCCESS_COUNT} report(s) — ${TODAY}" 2>&1 || {
    log_error "Git commit failed"
  }
  log "Committed vault changes"
else
  log "No vault changes to commit"
fi

###############################################################################
# Summary
###############################################################################

log "=== Run Complete ==="
log "  Successes: ${SUCCESS_COUNT}"
log "  Errors:    ${ERROR_COUNT}"
log "  Total:     $((SUCCESS_COUNT + ERROR_COUNT))"

exit 0
