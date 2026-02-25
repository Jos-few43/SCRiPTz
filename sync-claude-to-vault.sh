#!/bin/bash
# sync-claude-to-vault.sh — Sync Claude Code session transcripts to Obsidian vault.
#
# Triggered by Claude Code's SessionEnd hook. Reads hook JSON from stdin,
# parses the JSONL transcript, and writes a Markdown note into the vault.
#
# Usage (hook):
#   echo '{"session_id":"...","transcript_path":"...","cwd":"..."}' | bash sync-claude-to-vault.sh
#
# Usage (manual):
#   echo '{"session_id":"ses_abc","transcript_path":"${HOME}/.claude/transcripts/ses_abc.jsonl","cwd":"${HOME}"}' \
#     | bash ${HOME}/SCRiPTz/sync-claude-to-vault.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
VAULT_ROOT="${HOME}/Documents/OpenClaw-Vault"
LOG_DIR="$VAULT_ROOT/12-LOGS/claude-code"
DAILY_DIR="$VAULT_ROOT/03-DAILY"
MOC_FILE="$LOG_DIR/_index.md"
STATE_FILE="$HOME/.claude/vault-sync-state.json"
MAX_TOOL_OUTPUT_LINES=20
MIN_USER_MESSAGES=2
TITLE_MAX_CHARS=60
SLUG_MAX_CHARS=50

# ---------------------------------------------------------------------------
# Logging helper
# ---------------------------------------------------------------------------
log() { echo "[vault-sync] $*" >&2; }

# ---------------------------------------------------------------------------
# Read hook JSON from stdin
# ---------------------------------------------------------------------------
HOOK_JSON="$(cat)"
if [[ -z "$HOOK_JSON" ]]; then
    log "ERROR: No JSON received on stdin"
    exit 1
fi

SESSION_ID="$(echo "$HOOK_JSON" | jq -r '.session_id // empty')"
TRANSCRIPT_PATH="$(echo "$HOOK_JSON" | jq -r '.transcript_path // empty')"
CWD="$(echo "$HOOK_JSON" | jq -r '.cwd // empty')"

if [[ -z "$SESSION_ID" ]]; then
    log "ERROR: session_id missing from hook JSON"
    exit 1
fi
if [[ -z "$TRANSCRIPT_PATH" || ! -f "$TRANSCRIPT_PATH" ]]; then
    log "ERROR: transcript_path missing or file not found: $TRANSCRIPT_PATH"
    exit 1
fi

log "Processing session $SESSION_ID from $TRANSCRIPT_PATH"

# ---------------------------------------------------------------------------
# Idempotency check
# ---------------------------------------------------------------------------
if [[ ! -f "$STATE_FILE" ]]; then
    mkdir -p "$(dirname "$STATE_FILE")"
    echo '{"synced":[]}' > "$STATE_FILE"
fi

if jq -e --arg id "$SESSION_ID" '.synced | index($id)' "$STATE_FILE" >/dev/null 2>&1; then
    log "Session $SESSION_ID already synced, skipping"
    exit 0
fi

# ---------------------------------------------------------------------------
# Parse transcript
# ---------------------------------------------------------------------------

# Count user messages
REAL_USER_COUNT="$(jq -c 'select(.type=="user")' "$TRANSCRIPT_PATH" | wc -l)"

if (( REAL_USER_COUNT < MIN_USER_MESSAGES )); then
    log "Session $SESSION_ID has only $REAL_USER_COUNT user messages (minimum $MIN_USER_MESSAGES), skipping"
    # Still mark as synced to avoid re-processing
    jq --arg id "$SESSION_ID" '.synced += [$id]' "$STATE_FILE" > "${STATE_FILE}.tmp" \
        && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    exit 0
fi

# ---------------------------------------------------------------------------
# Extract metadata
# ---------------------------------------------------------------------------

# First timestamp for date
FIRST_TS="$(jq -s -r '.[0].timestamp // ""' "$TRANSCRIPT_PATH")"
SESSION_DATE="$(date -d "$FIRST_TS" '+%Y-%m-%d' 2>/dev/null || echo "$(date '+%Y-%m-%d')")"
SESSION_YEAR="$(echo "$SESSION_DATE" | cut -d- -f1)"
SESSION_MONTH="$(echo "$SESSION_DATE" | cut -d- -f2)"

# Project detection from cwd
PROJECT=""
if [[ -n "$CWD" ]]; then
    case "$CWD" in
        */PROJECTz/opencode-manager*) PROJECT="opencode-manager" ;;
        */PROJECTz/opencode-antigravity*) PROJECT="opencode-antigravity-multi-auth" ;;
        */PROJECTz/ai-container-configs*) PROJECT="ai-container-configs" ;;
        */distrobox-configs*) PROJECT="distrobox-configs" ;;
        */shared-skills*) PROJECT="shared-skills" ;;
        */litellm-stack*) PROJECT="litellm-stack" ;;
        */SCRiPTz*) PROJECT="SCRiPTz" ;;
        */NSTRUCTiONz*) PROJECT="NSTRUCTiONz" ;;
        */arr-media-stack*) PROJECT="arr-media-stack" ;;
        *) PROJECT="$(basename "$CWD")" ;;
    esac
fi

# Unique tool names used
TOOLS_USED="$(jq -r 'select(.type=="tool_use") | .tool_name' "$TRANSCRIPT_PATH" \
    | sort -u | head -30 || true)"

# Files touched: extract from read/edit/write/bash tool inputs
FILES_TOUCHED="$(jq -r '
    select(.type=="tool_use") |
    if (.tool_name | ascii_downcase) == "read" or (.tool_name | ascii_downcase) == "edit" or (.tool_name | ascii_downcase) == "write" then
        .tool_input.file_path // .tool_input.path // empty
    elif (.tool_name | ascii_downcase) == "bash" then
        empty
    elif (.tool_name | ascii_downcase) == "glob" then
        .tool_input.pattern // empty
    else
        empty
    end
' "$TRANSCRIPT_PATH" 2>/dev/null | sort -u | head -30 || true)"

# --- Task/Plan Extraction ---
TASKS_JSON=$(jq -c '
  select(.type=="tool_use") |
  select(.tool_name=="TaskCreate" or .tool_name=="TaskUpdate") |
  {tool: .tool_name, input: .tool_input}
' "$TRANSCRIPT_PATH" 2>/dev/null || true)

TASK_COUNT=0
if [ -n "$TASKS_JSON" ]; then
  TASK_COUNT=$(echo "$TASKS_JSON" | grep -c "TaskCreate" || true)
fi

# Count write operations for skill-candidate tagging
WRITE_OP_COUNT=$(jq -c 'select(.type=="tool_use") | select(.tool_name=="Edit" or .tool_name=="Write" or .tool_name=="MultiEdit")' "$TRANSCRIPT_PATH" 2>/dev/null | wc -l)

# ---------------------------------------------------------------------------
# Extract title from first real user message
# ---------------------------------------------------------------------------
extract_title() {
    # Extract first real user content line after stripping all XML-like tags
    local title
    title="$(jq -c 'select(.type=="user") | .content' "$TRANSCRIPT_PATH" \
        | python3 -c "
import sys, re, json
for line in sys.stdin:
    try:
        content = json.loads(line)
    except:
        continue
    # Strip all XML-like block tags (multiline within the content)
    cleaned = re.sub(r'<[a-zA-Z_][a-zA-Z0-9_-]*(?:\s[^>]*)?>.*?</[a-zA-Z_][a-zA-Z0-9_-]*>', '', content, flags=re.DOTALL)
    # Strip self-closing tags
    cleaned = re.sub(r'<[a-zA-Z_][a-zA-Z0-9_-]*/>', '', cleaned)
    # Find first non-empty line with real content
    for text_line in cleaned.strip().split('\n'):
        stripped = text_line.strip()
        if stripped and len(stripped) > 2:
            # Take first line only, truncate
            print(stripped[:${TITLE_MAX_CHARS}])
            sys.exit(0)
" 2>/dev/null)"

    if [[ -z "$title" ]]; then
        title="claude-session"
    fi

    echo "$title"
}

# Slugify a title for filename use
slugify() {
    local input="$1"
    echo "$input" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/-/g' \
        | sed -E 's/-+/-/g' \
        | sed -E 's/^-//; s/-$//' \
        | cut -c1-"$SLUG_MAX_CHARS"
}

# Sanitize title for YAML safety (strip trailing backslashes, quotes, control chars)
sanitize_title() {
    local t="$1"
    t="${t%\\}"          # strip trailing backslash
    t="${t//\"/\'}"      # replace double quotes with single
    t="$(echo "$t" | tr -d '\n\r\t')"  # strip control chars
    echo "$t"
}

TITLE="$(sanitize_title "$(extract_title)")"
SLUG="$(slugify "$TITLE")"
if [[ -z "$SLUG" ]]; then
    SLUG="claude-session"
fi

# ---------------------------------------------------------------------------
# Determine output path (handle collisions)
# ---------------------------------------------------------------------------
OUT_DIR="$LOG_DIR/$SESSION_YEAR/$SESSION_MONTH"
mkdir -p "$OUT_DIR"

BASE_NAME="$SESSION_DATE-$SLUG"
OUT_FILE="$OUT_DIR/${BASE_NAME}.md"
COUNTER=2
while [[ -f "$OUT_FILE" ]]; do
    OUT_FILE="$OUT_DIR/${BASE_NAME}-${COUNTER}.md"
    (( COUNTER++ ))
done

log "Writing to $OUT_FILE"

# ---------------------------------------------------------------------------
# Generate Markdown
# ---------------------------------------------------------------------------

# Build YAML frontmatter tools list
TOOLS_YAML=""
if [[ -n "$TOOLS_USED" ]]; then
    while IFS= read -r tool; do
        TOOLS_YAML="${TOOLS_YAML}  - ${tool}"$'\n'
    done <<< "$TOOLS_USED"
fi

# Build YAML frontmatter files list
FILES_YAML=""
if [[ -n "$FILES_TOUCHED" ]]; then
    while IFS= read -r fpath; do
        FILES_YAML="${FILES_YAML}  - \"${fpath}\""$'\n'
    done <<< "$FILES_TOUCHED"
fi

{
    # --- Frontmatter ---
    echo "---"
    echo "title: \"$TITLE\""
    echo "date: $SESSION_DATE"
    echo "session_id: \"$SESSION_ID\""
    echo "project: \"$PROJECT\""
    echo "cwd: \"$CWD\""
    echo "tags:"
    echo "  - claude-code"
    echo "  - session-log"
    if (( WRITE_OP_COUNT >= 3 )); then
        echo "  - skill-candidate"
    fi
    if (( TASK_COUNT > 0 )); then
        echo "  - has-plan"
    fi
    echo "tools_used:"
    if [[ -n "$TOOLS_YAML" ]]; then
        printf '%s' "$TOOLS_YAML"
    else
        echo "  []"
    fi
    echo "files_touched:"
    if [[ -n "$FILES_YAML" ]]; then
        printf '%s' "$FILES_YAML"
    else
        echo "  []"
    fi
    echo "---"

    echo ""
    echo "# $TITLE"
    echo ""
    echo "> Session \`$SESSION_ID\` on [[03-DAILY/$SESSION_DATE|$SESSION_DATE]]"
    if [[ -n "$PROJECT" ]]; then
        echo "> Project: **$PROJECT** (\`$CWD\`)"
    fi
    echo ""

    # --- Conversation body ---
    # Process each JSONL line
    jq -c '.' "$TRANSCRIPT_PATH" | while IFS= read -r line; do
        MSG_TYPE="$(echo "$line" | jq -r '.type')"
        TIMESTAMP="$(echo "$line" | jq -r '.timestamp // ""')"
        TS_DISPLAY=""
        if [[ -n "$TIMESTAMP" ]]; then
            TS_DISPLAY="$(date -d "$TIMESTAMP" '+%H:%M:%S' 2>/dev/null || echo "$TIMESTAMP")"
        fi

        case "$MSG_TYPE" in
            user)
                CONTENT="$(echo "$line" | jq -r '.content // ""')"
                # Strip XML-like block tags using python for multiline safety
                CLEANED="$(echo "$CONTENT" | python3 -c "
import sys, re
text = sys.stdin.read()
cleaned = re.sub(r'<[a-zA-Z_][a-zA-Z0-9_-]*>.*?</[a-zA-Z_][a-zA-Z0-9_-]*>', '', text, flags=re.DOTALL)
cleaned = re.sub(r'<[a-zA-Z_][a-zA-Z0-9_-]*/>', '', cleaned)
print(cleaned.strip())
" 2>/dev/null)"
                # Skip if empty after stripping
                if [[ -n "$CLEANED" ]]; then
                    echo "## User"
                    echo "*${TS_DISPLAY}*"
                    echo ""
                    echo "$CLEANED"
                    echo ""
                fi
                ;;

            tool_use)
                TOOL_NAME="$(echo "$line" | jq -r '.tool_name // "unknown"')"
                # Generate a human-readable summary for common tools
                TOOL_SUMMARY="$(echo "$line" | jq -r '
                    .tool_input as $in |
                    .tool_name as $name |
                    if ($name | ascii_downcase) == "bash" then
                        "`" + ($in.command // "?" | .[0:120]) + "`"
                    elif ($name | ascii_downcase) == "read" then
                        "`" + ($in.filePath // $in.file_path // "?") + "`"
                    elif ($name | ascii_downcase) == "edit" then
                        "`" + ($in.filePath // $in.file_path // "?") + "`"
                    elif ($name | ascii_downcase) == "write" then
                        "`" + ($in.filePath // $in.file_path // "?") + "`"
                    elif ($name | ascii_downcase) == "glob" then
                        "`" + ($in.pattern // "?") + "`"
                    elif ($name | ascii_downcase) == "grep" then
                        "`" + ($in.pattern // "?") + "`"
                    elif ($name | ascii_downcase) == "task" then
                        ($in.description // $in.prompt // "?" | .[0:80])
                    else
                        null
                    end
                ' 2>/dev/null)"

                echo "### \`$TOOL_NAME\`"
                echo "*${TS_DISPLAY}*"
                if [[ -n "$TOOL_SUMMARY" && "$TOOL_SUMMARY" != "null" ]]; then
                    echo "$TOOL_SUMMARY"
                fi
                echo ""
                echo "<details>"
                echo "<summary>Full parameters</summary>"
                echo ""
                echo '```json'
                echo "$line" | jq '.tool_input // {}' 2>/dev/null | head -30 || true
                echo '```'
                echo ""
                echo "</details>"
                echo ""
                ;;

            tool_result)
                TOOL_NAME="$(echo "$line" | jq -r '.tool_name // "unknown"')"
                # Extract output — try to unwrap common JSON envelopes
                # OpenCode wraps results like {"output":"...","exit":0,"truncated":false}
                # Claude Code CLI may use plain strings or {"content":"..."}
                TOOL_OUTPUT="$(echo "$line" | jq -r '
                    .tool_output as $out |
                    if ($out | type) == "object" then
                        if $out.output then
                            $out.output
                        elif $out.content then
                            $out.content
                        elif $out.preview then
                            $out.preview
                        elif $out.diff then
                            $out.diff
                        elif $out.prompt then
                            "(subagent dispatched)"
                        else
                            ($out | tostring)
                        end
                    elif ($out | type) == "string" then
                        $out
                    else
                        ($out | tostring)
                    end
                ' 2>/dev/null || echo "(unable to parse)")"

                # Truncate output
                OUTPUT_LINES="$(echo "$TOOL_OUTPUT" | wc -l)"
                if (( OUTPUT_LINES > MAX_TOOL_OUTPUT_LINES )); then
                    TRUNCATED_OUTPUT="$(echo "$TOOL_OUTPUT" | head -n "$MAX_TOOL_OUTPUT_LINES" || true)"
                    TRUNCATED_OUTPUT="${TRUNCATED_OUTPUT}"$'\n'"... (truncated, ${OUTPUT_LINES} total lines)"
                else
                    TRUNCATED_OUTPUT="$TOOL_OUTPUT"
                fi

                echo "<details>"
                echo "<summary>Tool Result: \`$TOOL_NAME\`</summary>"
                echo ""
                echo '```'
                echo "$TRUNCATED_OUTPUT"
                echo '```'
                echo ""
                echo "</details>"
                echo ""
                ;;

            assistant)
                CONTENT="$(echo "$line" | jq -r '.content // ""')"
                if [[ -n "$CONTENT" ]]; then
                    echo "## Assistant"
                    echo "*${TS_DISPLAY}*"
                    echo ""
                    echo "$CONTENT"
                    echo ""
                fi
                ;;

            *)
                # Unknown type, include raw
                echo "## $MSG_TYPE"
                echo "*${TS_DISPLAY}*"
                echo ""
                echo '```json'
                echo "$line" | jq '.' 2>/dev/null || echo "$line"
                echo '```'
                echo ""
                ;;
        esac
    done

    # --- Implementation Plan Section ---
    if [ -n "$TASKS_JSON" ] && (( TASK_COUNT > 0 )); then
        echo ""
        echo "## Implementation Plan"
        echo ""
        echo "$TASKS_JSON" | jq -r '
            select(.tool == "TaskCreate") |
            "- [ ] **" + (.input.subject // "Untitled") + "**" +
            if .input.description then "\n  " + .input.description else "" end
        ' 2>/dev/null || true
        echo ""
        COMPLETED=$(echo "$TASKS_JSON" | jq -r '
            select(.tool == "TaskUpdate") |
            select(.input.status == "completed") |
            .input.taskId // empty
        ' 2>/dev/null || true)
        if [ -n "$COMPLETED" ]; then
            echo "*Completed tasks: $(echo "$COMPLETED" | tr '\n' ', ' | sed 's/,$//')*"
            echo ""
        fi
    fi

} > "$OUT_FILE"

log "Wrote session note: $OUT_FILE"

# ---------------------------------------------------------------------------
# Update MOC (_index.md)
# ---------------------------------------------------------------------------
if [[ -f "$MOC_FILE" ]]; then
    RELATIVE_PATH="$SESSION_YEAR/$SESSION_MONTH/$(basename "$OUT_FILE" .md)"
    MOC_ENTRY="- [[$RELATIVE_PATH|$SESSION_DATE — $TITLE]]"

    # Insert before the marker using python3 for safety with special chars
    if grep -qF '<!-- NEW_SESSION_ENTRY -->' "$MOC_FILE"; then
        python3 -c "
import sys
moc_path, entry = sys.argv[1], sys.argv[2]
marker = '<!-- NEW_SESSION_ENTRY -->'
with open(moc_path, 'r') as f:
    content = f.read()
content = content.replace(marker, entry + '\n' + marker, 1)
with open(moc_path, 'w') as f:
    f.write(content)
" "$MOC_FILE" "$MOC_ENTRY"
        log "Updated MOC: $MOC_FILE"
    else
        log "WARNING: Marker <!-- NEW_SESSION_ENTRY --> not found in MOC"
    fi
else
    log "WARNING: MOC file not found: $MOC_FILE"
fi

# ---------------------------------------------------------------------------
# Update daily note
# ---------------------------------------------------------------------------
DAILY_FILE="$DAILY_DIR/$SESSION_DATE.md"

if [[ ! -f "$DAILY_FILE" ]]; then
    # Create minimal daily note
    DAY_NAME="$(date -d "$SESSION_DATE" '+%A' 2>/dev/null || echo "Day")"
    cat > "$DAILY_FILE" <<DAILY
---
title: "Daily Log - $SESSION_DATE"
created: $SESSION_DATE
updated: $SESSION_DATE
category: Daily
tags:
  - daily
  - log
  - $DAY_NAME
status: Active
---

# $SESSION_DATE - Daily Log

## Claude Code Sessions

DAILY
    log "Created daily note: $DAILY_FILE"
fi

# Check if "## Claude Code Sessions" section exists
if ! grep -qF '## Claude Code Sessions' "$DAILY_FILE"; then
    # Append the section
    printf '\n## Claude Code Sessions\n\n' >> "$DAILY_FILE"
    log "Added Claude Code Sessions section to daily note"
fi

# Append session link to the Claude Code Sessions section
RELATIVE_LOG="12-LOGS/claude-code/$SESSION_YEAR/$SESSION_MONTH/$(basename "$OUT_FILE" .md)"
DAILY_ENTRY="- [[$RELATIVE_LOG|$TITLE]] — \`$SESSION_ID\` ($PROJECT)"

python3 -c "
import sys, re

daily_path = sys.argv[1]
entry = sys.argv[2]

with open(daily_path, 'r') as f:
    lines = f.readlines()

# Find the '## Claude Code Sessions' line
marker_idx = None
for i, line in enumerate(lines):
    if line.strip() == '## Claude Code Sessions':
        marker_idx = i
        break

if marker_idx is None:
    # Fallback: append section at end
    lines.append('\n## Claude Code Sessions\n\n' + entry + '\n')
else:
    # Find the end of this section: next ## heading or end of file
    insert_idx = len(lines)
    for i in range(marker_idx + 1, len(lines)):
        if lines[i].startswith('## ') or lines[i].startswith('# '):
            # Insert before the blank line preceding the next section
            insert_idx = i
            # Back up over trailing blank lines
            while insert_idx > marker_idx + 1 and lines[insert_idx - 1].strip() == '':
                insert_idx -= 1
            break
    lines.insert(insert_idx, entry + '\n')

with open(daily_path, 'w') as f:
    f.writelines(lines)
" "$DAILY_FILE" "$DAILY_ENTRY"

log "Updated daily note: $DAILY_FILE"

# ---------------------------------------------------------------------------
# Generate standalone plan document (if tasks were created)
# ---------------------------------------------------------------------------
if (( TASK_COUNT > 0 )); then
    PLAN_DIR="$VAULT_ROOT/12-LOGS/claude-plans/$SESSION_YEAR/$SESSION_MONTH"
    mkdir -p "$PLAN_DIR"

    PLAN_FILE="$PLAN_DIR/${BASE_NAME}-plan.md"
    PLAN_COUNTER=2
    while [[ -f "$PLAN_FILE" ]]; do
        PLAN_FILE="$PLAN_DIR/${BASE_NAME}-plan-${PLAN_COUNTER}.md"
        (( PLAN_COUNTER++ ))
    done

    RELATIVE_SESSION="12-LOGS/claude-code/$SESSION_YEAR/$SESSION_MONTH/$(basename "$OUT_FILE" .md)"

    {
        echo "---"
        echo "title: \"Plan: $TITLE\""
        echo "date: $SESSION_DATE"
        echo "session_id: \"$SESSION_ID\""
        echo "project: \"$PROJECT\""
        echo "type: implementation-plan"
        echo "tags:"
        echo "  - plan"
        echo "  - claude-code"
        if (( WRITE_OP_COUNT >= 3 )); then
            echo "  - skill-candidate"
        fi
        echo "---"
        echo ""
        echo "# Plan: $TITLE"
        echo ""
        echo "> From session [[$RELATIVE_SESSION|$SESSION_DATE — $TITLE]]"
        echo "> Project: **$PROJECT**"
        echo ""
        echo "## Tasks"
        echo ""
        echo "$TASKS_JSON" | jq -r '
            select(.tool == "TaskCreate") |
            "- [ ] **" + (.input.subject // "Untitled") + "**" +
            if .input.description then "\n  " + .input.description else "" end +
            if .input.activeForm then "\n  *Active: " + .input.activeForm + "*" else "" end
        ' 2>/dev/null || true
        echo ""
    } > "$PLAN_FILE"

    log "Wrote plan document: $PLAN_FILE"

    # Update plans MOC
    PLAN_MOC="$VAULT_ROOT/12-LOGS/claude-plans/_index.md"
    if [[ -f "$PLAN_MOC" ]]; then
        RELATIVE_PLAN="$SESSION_YEAR/$SESSION_MONTH/$(basename "$PLAN_FILE" .md)"
        PLAN_MOC_ENTRY="- [[$RELATIVE_PLAN|$SESSION_DATE — $TITLE]] ($PROJECT)"

        if grep -qF '<!-- NEW_PLAN_ENTRY -->' "$PLAN_MOC"; then
            python3 -c "
import sys
moc_path, entry = sys.argv[1], sys.argv[2]
marker = '<!-- NEW_PLAN_ENTRY -->'
with open(moc_path, 'r') as f:
    content = f.read()
content = content.replace(marker, entry + '\n' + marker, 1)
with open(moc_path, 'w') as f:
    f.write(content)
" "$PLAN_MOC" "$PLAN_MOC_ENTRY"
            log "Updated plans MOC: $PLAN_MOC"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Mark session as synced
# ---------------------------------------------------------------------------
jq --arg id "$SESSION_ID" '.synced += [$id]' "$STATE_FILE" > "${STATE_FILE}.tmp" \
    && mv "${STATE_FILE}.tmp" "$STATE_FILE"

log "Session $SESSION_ID synced successfully"
log "Output: $OUT_FILE"

# ---------------------------------------------------------------------------
# Run memory extractor (best-effort, don't fail the hook)
# ---------------------------------------------------------------------------
MEMORY_EXTRACTOR="${HOME}/OpenClaw-Vault/scripts/vault-importer/src/memory-extractor.ts"
if [[ -f "$MEMORY_EXTRACTOR" ]] && command -v bun &>/dev/null; then
    bun run "$MEMORY_EXTRACTOR" "$TRANSCRIPT_PATH" 2>&1 | while read -r line; do
        log "$line"
    done || log "WARNING: memory extractor failed (non-fatal)"
else
    log "INFO: memory extractor not available (missing bun or script)"
fi
