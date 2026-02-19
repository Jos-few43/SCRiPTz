#!/bin/bash
# Sync Anthropic OAuth token from Claude Code credentials into OpenClaw config.
# Reads: ~/.claude/.credentials.json
# Writes: ~/.openclaw/openclaw.json (apiKey field for anthropic provider)
#
# Usage:
#   bash ~/.openclaw/sync-anthropic-token.sh          # one-shot sync
#   bash ~/.openclaw/sync-anthropic-token.sh --watch   # watch mode (continuous)

set -euo pipefail

CREDS="$HOME/.claude/.credentials.json"
CONFIG="$HOME/.openclaw/openclaw.json"

sync_token() {
  if [[ ! -f "$CREDS" ]]; then
    echo "[sync-token] ERROR: $CREDS not found" >&2
    return 1
  fi
  if [[ ! -f "$CONFIG" ]]; then
    echo "[sync-token] ERROR: $CONFIG not found" >&2
    return 1
  fi

  local new_token
  new_token=$(python3 -c "
import json, sys
with open('$CREDS') as f:
    data = json.load(f)
token = data.get('claudeAiOauth', {}).get('accessToken', '')
if not token:
    print('', end='')
    sys.exit(1)
print(token, end='')
" 2>/dev/null)

  if [[ -z "$new_token" ]]; then
    echo "[sync-token] ERROR: no accessToken in $CREDS" >&2
    return 1
  fi

  # Read current token from openclaw config
  local current_token
  current_token=$(python3 -c "
import json
with open('$CONFIG') as f:
    data = json.load(f)
print(data.get('models',{}).get('providers',{}).get('anthropic',{}).get('apiKey',''), end='')
" 2>/dev/null)

  if [[ "$new_token" == "$current_token" ]]; then
    return 0
  fi

  # Update the token in openclaw.json
  python3 -c "
import json

with open('$CONFIG') as f:
    config = json.load(f)

config['models']['providers']['anthropic']['apiKey'] = '$new_token'

with open('$CONFIG', 'w') as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
    f.write('\n')
"

  echo "[sync-token] Token updated ($(date '+%H:%M:%S'))"
}

if [[ "${1:-}" == "--watch" ]]; then
  echo "[sync-token] Watching $CREDS for changes..."
  sync_token || true

  # Use inotifywait if available, otherwise poll
  if command -v inotifywait &>/dev/null; then
    while true; do
      inotifywait -qq -e modify -e create "$CREDS" 2>/dev/null
      sleep 1  # debounce
      sync_token || true
    done
  else
    while true; do
      sleep 300  # poll every 5 minutes
      sync_token || true
    done
  fi
else
  sync_token
fi
