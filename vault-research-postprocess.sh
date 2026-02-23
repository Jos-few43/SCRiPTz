#!/usr/bin/env bash
set -euo pipefail

# vault-research-postprocess.sh — Update Obsidian vault knowledge graph after
# a new research report is written.
#
# Usage:
#   bash vault-research-postprocess.sh <report-path> <theme> <title> <date>
#
# Example:
#   bash vault-research-postprocess.sh \
#     ~/Documents/OpenClaw-Vault/01-RESEARCH/AI-Safety/goal-drift.md \
#     "AI-Safety" "Goal Drift Detection" "2026-02-22"

###############################################################################
# Argument validation
###############################################################################

if [[ $# -lt 4 ]]; then
  echo "Usage: $0 <report-path> <theme> <title> <date>"
  echo ""
  echo "Arguments:"
  echo "  report-path  Absolute path to the research report .md file"
  echo "  theme        Theme name (e.g. AI-Safety, Token-Efficiency)"
  echo "  title        Human-readable title of the report"
  echo "  date         Date in YYYY-MM-DD format"
  exit 1
fi

REPORT_PATH="$1"
THEME="$2"
TITLE="$3"
DATE="$4"

VAULT="${VAULT_PATH:-$HOME/Documents/OpenClaw-Vault}"

###############################################################################
# Derived values
###############################################################################

SLUG="$(basename "$REPORT_PATH" .md)"
THEME_MOC="$VAULT/00-INDEX/Theme-${THEME}.md"
RESEARCH_INDEX="$VAULT/00-INDEX/Research-Index.md"
TOPICS_FILE="$VAULT/01-RESEARCH/TOPICS.md"

###############################################################################
# Validate inputs
###############################################################################

if [[ ! -f "$REPORT_PATH" ]]; then
  echo "[postprocess] ERROR: Report file not found: $REPORT_PATH"
  exit 1
fi

if [[ ! -d "$VAULT" ]]; then
  echo "[postprocess] ERROR: Vault directory not found: $VAULT"
  exit 1
fi

echo "[postprocess] Processing report: $SLUG"
echo "[postprocess]   Theme: $THEME"
echo "[postprocess]   Title: $TITLE"
echo "[postprocess]   Date:  $DATE"

###############################################################################
# Step 1: Update Theme MOC
###############################################################################

echo "[postprocess] Step 1: Update Theme MOC"

if [[ -f "$THEME_MOC" ]]; then
  if grep -qF "$SLUG" "$THEME_MOC"; then
    echo "[postprocess]   Already listed in Theme MOC — skipping"
  else
    echo "- [[01-RESEARCH/${THEME}/${SLUG}|${TITLE}]] — ${DATE} (auto-generated)" >> "$THEME_MOC"
    echo "[postprocess]   Appended to $THEME_MOC"
  fi
else
  echo "[postprocess]   Theme MOC not found: $THEME_MOC — skipping"
fi

###############################################################################
# Step 2: Update Research-Index.md
###############################################################################

echo "[postprocess] Step 2: Update Research-Index.md"

if [[ -f "$RESEARCH_INDEX" ]]; then
  if grep -qF "$SLUG" "$RESEARCH_INDEX"; then
    echo "[postprocess]   Already listed in Research-Index — skipping"
  else
    echo "- [[01-RESEARCH/${THEME}/${SLUG}|${TITLE}]] — ${THEME} — ${DATE}" >> "$RESEARCH_INDEX"
    echo "[postprocess]   Appended to $RESEARCH_INDEX"
  fi
else
  echo "[postprocess]   Research-Index not found: $RESEARCH_INDEX — skipping"
fi

###############################################################################
# Step 3: Seed follow-up topics from Section 7
###############################################################################

echo "[postprocess] Step 3: Seed follow-up topics from Section 7"

# Extract content between ## 7. and ## 8. (or end of file)
SECTION7=""
if grep -qP '^## 7\.' "$REPORT_PATH"; then
  SECTION7="$(sed -n '/^## 7\./,/^## 8\./{ /^## 7\./d; /^## 8\./d; p; }' "$REPORT_PATH")"
fi

if [[ -z "$SECTION7" || -z "$(echo "$SECTION7" | tr -d '[:space:]')" ]]; then
  echo "[postprocess]   No Section 7 content found — skipping"
else
  if [[ -f "$TOPICS_FILE" ]]; then
    # Check idempotency: don't add if this follow-up block already exists
    if grep -qF "Follow-ups from ${TITLE}" "$TOPICS_FILE"; then
      echo "[postprocess]   Follow-ups already seeded in TOPICS.md — skipping"
    else
      {
        echo ""
        echo "## [Pending] Follow-ups from ${TITLE}"
        echo "Priority: P3"
        echo "Status: Pending"
        echo "Created: ${DATE}"
        echo "Source: [[01-RESEARCH/${THEME}/${SLUG}|${TITLE}]] §7"
        echo ""
        echo "$SECTION7"
      } >> "$TOPICS_FILE"
      echo "[postprocess]   Appended follow-up topics to $TOPICS_FILE"
    fi
  else
    echo "[postprocess]   TOPICS.md not found: $TOPICS_FILE — skipping"
  fi
fi

###############################################################################
# Step 4: Create stubs for dead wikilinks
###############################################################################

echo "[postprocess] Step 4: Create stubs for dead wikilinks"

STUB_COUNT=0

# Extract all wikilinks from report
grep -oP '\[\[\K[^\]]+' "$REPORT_PATH" 2>/dev/null | while IFS= read -r raw_link; do
  # Strip display name after |
  target="${raw_link%%|*}"

  # Skip links containing http, #, or 03-DAILY
  if [[ "$target" == *http* || "$target" == *"#"* || "$target" == *03-DAILY* ]]; then
    continue
  fi

  # Resolve target to a file path
  # Try as-is first (relative to vault root), then try with .md extension
  target_file=""
  if [[ -f "$VAULT/${target}" ]]; then
    continue
  elif [[ -f "$VAULT/${target}.md" ]]; then
    continue
  else
    # Also check basename match (Obsidian resolves bare names)
    basename_target="$(basename "$target")"
    if find "$VAULT" -not -type l -name "${basename_target}.md" -print -quit 2>/dev/null | grep -q .; then
      continue
    fi
  fi

  # Dead link — create stub
  # Determine the stub file path
  if [[ "$target" == */* ]]; then
    stub_path="$VAULT/${target}.md"
  else
    # Bare link — place in 06-TERMINOLOGY by default
    stub_path="$VAULT/06-TERMINOLOGY/${target}.md"
  fi

  # Don't overwrite existing files
  if [[ -f "$stub_path" ]]; then
    continue
  fi

  # Create parent directory if needed
  mkdir -p "$(dirname "$stub_path")"

  # Derive a human-readable topic name from the target
  topic_name="$(basename "$target" | sed 's/-/ /g')"

  cat > "$stub_path" <<STUB
---
title: "${topic_name}"
date: ${DATE}
type: stub
status: needs-research
tags:
  - stub
  - needs-research
generated_by: claude-deep-research
---

# ${topic_name}

> Stub created automatically. Referenced in [[${SLUG}]].

#stub #needs-research
STUB

  echo "[postprocess]   Created stub: $stub_path"
done

echo "[postprocess]   Stub creation complete"

###############################################################################
# Step 5: Log related terminology
###############################################################################

echo "[postprocess] Step 5: Log related terminology"

REPORT_CONTENT="$(cat "$REPORT_PATH")"
TERM_COUNT=0

if [[ -d "$VAULT/06-TERMINOLOGY" ]]; then
  find "$VAULT/06-TERMINOLOGY" -not -type l -name '*.md' -print0 2>/dev/null \
    | while IFS= read -r -d '' term_file; do
        term_name="$(basename "$term_file" .md)"
        # Case-insensitive search for term name in report content
        if echo "$REPORT_CONTENT" | grep -qi "$term_name" 2>/dev/null; then
          echo "[postprocess]   Found terminology match: $term_name (in 06-TERMINOLOGY/)"
        fi
      done
else
  echo "[postprocess]   06-TERMINOLOGY/ not found — skipping"
fi

###############################################################################
# Done
###############################################################################

echo "[postprocess] Complete. Report '$TITLE' integrated into vault."
exit 0
