#!/usr/bin/env bash
set -uo pipefail

# Backfill all existing Claude Code transcripts into OpenClaw-Vault.
# Runs sync-claude-to-vault.sh for each transcript file.

TRANSCRIPTS_DIR="$HOME/.claude/transcripts"
SYNC_SCRIPT="${HOME}/SCRiPTz/sync-claude-to-vault.sh"

if [[ ! -d "$TRANSCRIPTS_DIR" ]]; then
    echo "ERROR: Transcripts directory not found: $TRANSCRIPTS_DIR" >&2
    exit 1
fi

COUNT=0
SKIPPED=0
ERRORS=0

for transcript in "$TRANSCRIPTS_DIR"/*.jsonl; do
    [[ -f "$transcript" ]] || continue

    SESSION_ID="$(basename "$transcript" .jsonl)"

    echo "--- Processing: $SESSION_ID ---"

    if echo "{\"session_id\":\"$SESSION_ID\",\"transcript_path\":\"$transcript\",\"cwd\":\"${HOME}\",\"hook_event_name\":\"SessionEnd\",\"reason\":\"backfill\"}" \
        | bash "$SYNC_SCRIPT" 2>&1; then
        COUNT=$((COUNT + 1))
    else
        EXIT_CODE=$?
        if [[ $EXIT_CODE -eq 0 ]]; then
            SKIPPED=$((SKIPPED + 1))
        else
            ERRORS=$((ERRORS + 1))
            echo "  ERROR (exit $EXIT_CODE) for $SESSION_ID" >&2
        fi
    fi
done

echo ""
echo "=== Backfill Complete ==="
echo "  Synced:  $COUNT"
echo "  Skipped: $SKIPPED"
echo "  Errors:  $ERRORS"
