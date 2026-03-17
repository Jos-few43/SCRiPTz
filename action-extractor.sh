#!/usr/bin/env bash
# action-extractor.sh — Extract actionable signals from research reports
# Usage: action-extractor.sh <report-path> | action-extractor.sh --scan-recent
set -uo pipefail

RADAR_FILE="${HOME}/shared-memory/core/tech-radar.md"
QUEUE_SCRIPT="${HOME}/SCRiPTz/action-queue.sh"
VAULT="${VAULT_PATH:-$HOME/Documents/OpenClaw-Vault}"

# --- Signal patterns (Tier 1: regex) ---
# Format: "pattern|action_type|urgency"
SIGNAL_PATTERNS=(
  'vulnerability|CVE-|security flaw|action_type=upgrade|urgency=critical'
  'deprecated|end-of-life|sunset|discontinued|action_type=deprecate|urgency=high'
  'breaking change|incompatible|action_type=upgrade|urgency=high'
  'replaces|superseded by|successor|action_type=evaluate|urgency=high'
  'recommended upgrade|should upgrade|action_type=upgrade|urgency=medium'
  'outperforms|significantly better|state-of-the-art|action_type=evaluate|urgency=medium'
  'new release|now available|just released|action_type=evaluate|urgency=low'
  'remove|no longer needed|obsolete|action_type=remove|urgency=medium'
)

# --- Helpers ---

log() { echo "[action-extractor] $*" >&2; }

# Load known component names from tech radar
load_components() {
  if [[ ! -f "$RADAR_FILE" ]]; then
    log "Warning: Tech radar not found at $RADAR_FILE"
    return
  fi
  grep '  - name: ' "$RADAR_FILE" 2>/dev/null | sed 's/.*name: "//;s/".*//' | sort -u
}

# Extract paragraph around a match (3 lines before + match + 3 lines after)
extract_context() {
  local file="$1" line_num="$2"
  local start=$((line_num - 3))
  [[ $start -lt 1 ]] && start=1
  local end=$((line_num + 3))
  sed -n "${start},${end}p" "$file" 2>/dev/null
}

# Match component name in text
match_component() {
  local text="$1"
  local components
  components=$(load_components)
  [[ -z "$components" ]] && return 1

  while IFS= read -r comp; do
    [[ -z "$comp" ]] && continue
    # Case-insensitive match — escape dots for regex
    local escaped
    escaped=$(echo "$comp" | sed 's/\./\\./g')
    if echo "$text" | grep -qi "$escaped" 2>/dev/null; then
      echo "$comp"
      return 0
    fi
  done <<< "$components"
  return 1
}

# --- Tier 1: Regex signal extraction ---

extract_tier1() {
  local report_path="$1"
  local report_name
  report_name=$(basename "$report_path" .md)
  local found=0

  log "Tier 1: Scanning $report_name for signal patterns..."

  for signal_def in "${SIGNAL_PATTERNS[@]}"; do
    # Parse signal definition
    local patterns action_type urgency
    # Split on | — first parts are patterns, last two are metadata
    local parts=()
    IFS='|' read -ra parts <<< "$signal_def"
    local n=${#parts[@]}
    urgency=$(echo "${parts[$((n-1))]}" | sed 's/urgency=//')
    action_type=$(echo "${parts[$((n-2))]}" | sed 's/action_type=//')

    # Build grep pattern from remaining parts
    local grep_pattern=""
    for ((i=0; i<n-2; i++)); do
      [[ -n "$grep_pattern" ]] && grep_pattern+="|"
      grep_pattern+="${parts[$i]}"
    done

    # Search for pattern matches with line numbers
    while IFS=: read -r line_num match_line; do
      [[ -z "$line_num" ]] && continue

      # Extract context paragraph
      local context
      context=$(extract_context "$report_path" "$line_num")

      # Try to match a known component
      local component
      component=$(match_component "$context") || true

      if [[ -n "$component" ]]; then
        # Component matched — create queue entry
        local title="${action_type}: ${component} — signal from ${report_name}"
        local rationale
        rationale=$(echo "$match_line" | head -c 200)

        log "  Signal: $action_type ($urgency) → $component"
        bash "$QUEUE_SCRIPT" add \
          --component "$component" \
          --category "$(get_component_category "$component")" \
          --action-type "$action_type" \
          --urgency "$urgency" \
          --title "$title" \
          --rationale "$rationale" \
          --source-report "$report_path" 2>&1 || true
        found=$((found + 1))
      else
        # No component match — queue for Tier 2 if configured
        log "  Signal found but no component match (line $line_num): ${match_line:0:80}"
        # Store for potential LLM fallback
        echo "${line_num}|${action_type}|${urgency}|${match_line:0:200}" >> "/tmp/action-extractor-ambiguous-$$" 2>/dev/null || true
      fi
    done < <(grep -niE "$grep_pattern" "$report_path" 2>/dev/null || true)
  done

  log "Tier 1 complete: $found actions queued"
  echo "$found"
}

# Get category for a component from the radar
get_component_category() {
  local component="$1"
  if [[ ! -f "$RADAR_FILE" ]]; then
    echo "tool"
    return
  fi
  # Find the component and extract its category
  local cat
  cat=$(python3 -c "
import re
with open('$RADAR_FILE') as f:
    content = f.read()
pattern = re.compile(r'  - name: \"?${component}\"?\n    category: (\w+)')
m = pattern.search(content)
print(m.group(1) if m else 'tool')
" 2>/dev/null) || cat="tool"
  echo "$cat"
}

# --- Tier 2: LLM fallback for ambiguous matches ---

extract_tier2() {
  local report_path="$1"
  local ambiguous_file="/tmp/action-extractor-ambiguous-$$"
  [[ ! -f "$ambiguous_file" ]] && return 0

  local count
  count=$(wc -l < "$ambiguous_file")
  [[ "$count" -eq 0 ]] && return 0

  log "Tier 2: $count ambiguous signals — attempting LLM extraction..."

  # Check if claude CLI is available
  if ! command -v claude &>/dev/null; then
    log "  claude CLI not found — skipping Tier 2"
    rm -f "$ambiguous_file"
    return 0
  fi

  # Build context for LLM
  local components
  components=$(load_components | head -50 | tr '\n' ', ')

  local ambiguous_text
  ambiguous_text=$(cat "$ambiguous_file")

  local prompt
  prompt="You are analyzing research report excerpts for actionable signals about technology components.

Known components: ${components}

For each excerpt below, determine:
1. Which component (from the known list) is being referenced, if any
2. The action type: upgrade, deprecate, add, remove, evaluate
3. Urgency: critical, high, medium, low
4. A brief title

Excerpts:
${ambiguous_text}

Respond with one JSON object per line, format:
{\"component\": \"name\", \"action_type\": \"...\", \"urgency\": \"...\", \"title\": \"...\", \"rationale\": \"...\"}

Only include lines where you can confidently match a component. Output nothing for unmatched lines."

  local llm_output
  llm_output=$(echo "$prompt" | claude --print 2>/dev/null) || true

  if [[ -n "$llm_output" ]]; then
    local llm_found=0
    while IFS= read -r json_line; do
      [[ -z "$json_line" || "$json_line" != "{"* ]] && continue
      # Parse and create queue entry
      local comp at urg title rat
      comp=$(echo "$json_line" | jq -r '.component // empty' 2>/dev/null) || continue
      at=$(echo "$json_line" | jq -r '.action_type // "evaluate"' 2>/dev/null)
      urg=$(echo "$json_line" | jq -r '.urgency // "low"' 2>/dev/null)
      title=$(echo "$json_line" | jq -r '.title // empty' 2>/dev/null)
      rat=$(echo "$json_line" | jq -r '.rationale // ""' 2>/dev/null)
      [[ -z "$comp" || -z "$title" ]] && continue

      bash "$QUEUE_SCRIPT" add \
        --component "$comp" \
        --category "$(get_component_category "$comp")" \
        --action-type "$at" \
        --urgency "$urg" \
        --title "$title" \
        --rationale "$rat" \
        --source-report "$report_path" 2>&1 || true
      llm_found=$((llm_found + 1))
    done <<< "$llm_output"
    log "Tier 2 complete: $llm_found actions queued from LLM"
  fi

  rm -f "$ambiguous_file"
}

# --- Scan recent reports ---

scan_recent() {
  local hours="${1:-24}"
  log "Scanning reports modified in last ${hours}h..."

  local total=0
  while IFS= read -r report; do
    [[ -z "$report" ]] && continue
    log "Processing: $(basename "$report")"
    local found
    found=$(extract_tier1 "$report")
    extract_tier2 "$report"
    total=$((total + found))
  done < <(find "$VAULT" -path '*/01-RESEARCH/*.md' -mmin "-$((hours * 60))" -not -name 'TOPICS.md' -not -name '*MOC*' -not -name '*Index*' 2>/dev/null || true)

  if [[ -d "$VAULT/030-sources/research" ]]; then
    while IFS= read -r report; do
      [[ -z "$report" ]] && continue
      log "Processing: $(basename "$report")"
      local found
      found=$(extract_tier1 "$report")
      extract_tier2 "$report"
      total=$((total + found))
    done < <(find "$VAULT/030-sources/research" -name '*.md' -mmin "-$((hours * 60))" 2>/dev/null || true)
  fi

  log "Scan complete: $total total actions queued"
  # Regenerate dashboard if any actions were found
  [[ $total -gt 0 ]] && bash "$QUEUE_SCRIPT" dashboard 2>/dev/null || true
}

# --- Main ---

case "${1:-}" in
  --scan-recent)
    scan_recent "${2:-24}"
    ;;
  --help|-h)
    echo "action-extractor.sh — Extract actionable signals from research reports"
    echo ""
    echo "Usage:"
    echo "  action-extractor.sh <report-path>        Extract from single report"
    echo "  action-extractor.sh --scan-recent [hours] Scan reports from last N hours (default: 24)"
    ;;
  "")
    echo "Error: provide a report path or --scan-recent" >&2
    exit 1
    ;;
  *)
    # Single report mode
    report="$1"
    [[ ! -f "$report" ]] && { echo "Error: File not found: $report" >&2; exit 1; }
    found=$(extract_tier1 "$report")
    extract_tier2 "$report"
    [[ "$found" -gt 0 ]] && bash "$QUEUE_SCRIPT" dashboard 2>/dev/null || true
    ;;
esac

# Cleanup temp files
rm -f "/tmp/action-extractor-ambiguous-$$" 2>/dev/null || true
