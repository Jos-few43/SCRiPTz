#!/usr/bin/env bash
set -uo pipefail
# Note: no -e so individual failures don't abort the whole run

# sync-research-pipelines.sh — Unified Research Pipeline Bridge
#
# Direction 1 (B→A): OpenClaw memory/research/reports/ → Obsidian vault
# Direction 2 (A→B): Vault gap scanner → OpenClaw TOPICS.md
#
# Usage: bash sync-research-pipelines.sh [--dry-run] [--dir1-only] [--dir2-only]

VAULT="${VAULT_PATH:-$HOME/Documents/OpenClaw-Vault}"
OPENCLAW_REPORTS="$HOME/.openclaw/workspace/memory/research/reports"
OPENCLAW_TOPICS="$HOME/.openclaw/workspace/memory/research/TOPICS.md"
AUTOPROCESS="$HOME/SCRiPTz/vault-research-autoprocess.sh"
GAP_SCANNER="$HOME/SCRiPTz/vault-gap-scanner.sh"
SYNC_STATE="$HOME/.openclaw/workspace/memory/research/pipeline-sync-state.json"
TODAY="$(date +%Y-%m-%d)"
LOG="$HOME/.openclaw/workspace/memory/heartbeat.log"

DRY_RUN=false DIR1_ONLY=false DIR2_ONLY=false
for arg in "$@"; do
  case "$arg" in --dry-run) DRY_RUN=true ;; --dir1-only) DIR1_ONLY=true ;; --dir2-only) DIR2_ONLY=true ;; esac
done

log() { local ts; ts="$(date '+%H:%M:%S')"; echo "[$ts] [pipeline-sync] $*" | tee -a "$LOG"; }

init_state() {
  [[ ! -f "$SYNC_STATE" ]] && echo '{"synced_reports":[],"last_gap_feed":null,"last_run":null}' > "$SYNC_STATE"
}

already_synced() {
  python3 -c "
import json, sys
try:
    s = json.load(open('$SYNC_STATE'))
    sys.exit(0 if sys.argv[1] in s.get('synced_reports',[]) else 1)
except: sys.exit(1)
" "$1" 2>/dev/null
}

mark_synced() {
  python3 -c "
import json, sys
slug = sys.argv[1]
f = '$SYNC_STATE'
try: s = json.load(open(f))
except: s = {'synced_reports': [], 'last_gap_feed': None, 'last_run': None}
sr = s.setdefault('synced_reports', [])
if slug not in sr: sr.append(slug)
s['last_run'] = '$TODAY'
json.dump(s, open(f, 'w'), indent=2)
" "$1" 2>/dev/null
}

topic_exists() {
  grep -qiF "$1" "$OPENCLAW_TOPICS" 2>/dev/null
}

###############################################################################
# Direction 1: Reports → Vault
###############################################################################
sync_reports_to_vault() {
  log "=== Dir1: Reports → Vault ==="
  [[ ! -d "$OPENCLAW_REPORTS" ]] && { log "No reports dir"; return; }
  [[ ! -f "$AUTOPROCESS" ]] && { log "No autoprocess script"; return; }

  local synced=0 skipped=0 failed=0

  for report in "$OPENCLAW_REPORTS"/*.md; do
    [[ -f "$report" ]] || continue
    local slug
    slug="$(basename "$report" .md)"
    [[ "$slug" == "README" ]] && continue

    # Skip if already tracked as synced
    if already_synced "$slug"; then
      (( skipped++ )) || true
      continue
    fi

    local lines
    lines="$(wc -l < "$report" 2>/dev/null || echo 0)"
    if (( lines < 10 )); then
      log "Skip thin ($lines ln): $slug"
      mark_synced "$slug"  # mark so we don't check again
      (( skipped++ )) || true
      continue
    fi

    if $DRY_RUN; then
      log "[DRY] Would sync: $slug"
      mark_synced "$slug"
      (( synced++ )) || true
      continue
    fi

    local rc=0
    bash "$AUTOPROCESS" "$report" >> "$LOG" 2>&1 || rc=$?
    # rc=0 means success OR "no changes" — both are fine
    mark_synced "$slug"
    (( synced++ )) || true
    log "✓ $slug"
  done

  log "Dir1: synced=$synced skipped=$skipped"
}

###############################################################################
# Direction 2: Vault gaps → TOPICS.md
###############################################################################
feed_gaps_to_topics() {
  log "=== Dir2: Vault gaps → TOPICS.md ==="
  [[ ! -f "$GAP_SCANNER" ]] && { log "No gap scanner"; return; }
  [[ ! -f "$OPENCLAW_TOPICS" ]] && { log "No TOPICS.md"; return; }

  # 6-hour cooldown
  local elapsed=99999
  elapsed="$(python3 -c "
import json, time
from datetime import datetime, timezone
try:
    s = json.load(open('$SYNC_STATE'))
    last = s.get('last_gap_feed')
    if last:
        dt = datetime.fromisoformat(last)
        print(int(time.time() - dt.timestamp()))
    else: print(99999)
except: print(99999)
" 2>/dev/null || echo 99999)"

  if (( elapsed < 21600 )); then
    local remain=$(( (21600 - elapsed) / 60 ))
    log "Gap feed cooldown: ${remain}min remaining"
    return
  fi

  log "Running gap scanner..."
  local gaps_json rc=0
  gaps_json="$(bash "$GAP_SCANNER" 2>/dev/null)" || rc=$?
  [[ -z "$gaps_json" || "$gaps_json" == "[]" ]] && { log "No gaps"; _update_gap_ts; return; }

  local total
  total="$(echo "$gaps_json" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)"
  log "$total gap(s) found"

  local added=0 exists=0

  while IFS= read -r gap; do
    [[ -z "$gap" ]] && continue
    local topic priority gap_type ctx
    topic="$(echo "$gap" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('topic',''))")"
    priority="$(echo "$gap" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('priority','P3'))")"
    gap_type="$(echo "$gap" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('gap_type','stub'))")"
    ctx="$(echo "$gap" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('context','')[:200])")"

    [[ -z "$topic" ]] && continue

    if topic_exists "$topic"; then
      (( exists++ )) || true
      continue
    fi

    if $DRY_RUN; then
      log "[DRY] Would add [$priority]: $topic"
    else
      printf '\n## [PENDING] %s\nPriority: %s\nStatus: Pending\nCreated: %s\nSource: vault-gap-scanner\nGapType: %s\nDescription: %s (vault gap)\n' \
        "$topic" "$priority" "$TODAY" "$gap_type" "$ctx" >> "$OPENCLAW_TOPICS"
      log "✓ Added [$priority]: $topic"
    fi
    (( added++ )) || true
    (( added >= 5 )) && { log "Cap 5/run reached"; break; }
  done < <(echo "$gaps_json" | python3 -c "import json,sys; [print(json.dumps(g)) for g in json.load(sys.stdin)]" 2>/dev/null)

  _update_gap_ts
  log "Dir2: added=$added already_existed=$exists"
}

_update_gap_ts() {
  python3 -c "
import json
from datetime import datetime, timezone
f = '$SYNC_STATE'
try: s = json.load(open(f))
except: s = {}
s['last_gap_feed'] = datetime.now(timezone.utc).isoformat()
s['last_run'] = '$TODAY'
json.dump(s, open(f, 'w'), indent=2)
" 2>/dev/null || true
}

commit_vault() {
  $DRY_RUN && return
  local rc=0
  cd "$VAULT" 2>/dev/null || return
  if git status --porcelain 2>/dev/null | grep -q .; then
    git add -A && git commit -m "research: pipeline-sync ${TODAY}" >> "$LOG" 2>&1 || rc=$?
    log "Vault committed (rc=$rc)"
  else
    log "Vault: no changes"
  fi
}

###############################################################################
log "=== Pipeline Sync ${TODAY} ==="
$DRY_RUN && log "*** DRY-RUN ***"
init_state
$DIR2_ONLY || sync_reports_to_vault
$DIR1_ONLY || feed_gaps_to_topics
commit_vault
python3 -c "
import json
from datetime import datetime, timezone
f = '$SYNC_STATE'
try: s = json.load(open(f))
except: s = {}
s['last_run'] = datetime.now(timezone.utc).isoformat()
json.dump(s, open(f, 'w'), indent=2)
" 2>/dev/null
log "=== Done ==="
