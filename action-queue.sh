#!/usr/bin/env bash
# action-queue.sh — Action queue management CLI
# Usage: action-queue.sh <subcommand> [args]
# Subcommands: add, list, approve, reject, implement, complete, fail, dashboard, notify
set -euo pipefail

QUEUE_FILE="${HOME}/shared-memory/core/action-queue.json"
DASHBOARD_FILE="${HOME}/shared-memory/core/action-queue.md"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TODAY=$(date -u +%Y-%m-%d)

# Ensure queue file exists
[[ -f "$QUEUE_FILE" ]] || echo '{"version":1,"actions":[]}' > "$QUEUE_FILE"

# --- Helpers ---

next_id() {
  local date_part
  date_part=$(date -u +%Y-%m%d)
  local count
  count=$(jq --arg dp "$date_part" '[.actions[] | select(.id | startswith("ACT-" + $dp))] | length' "$QUEUE_FILE")
  printf "ACT-%s-%03d" "$date_part" "$((count + 1))"
}

update_status() {
  local id="$1" new_status="$2" field="${3:-}" value="${4:-}"
  local timestamp_field=""
  case "$new_status" in
    approved)      timestamp_field="approved_at" ;;
    implementing)  timestamp_field="implemented_at" ;;
    validating)    timestamp_field="validated_at" ;;
    done)          timestamp_field="validated_at" ;;
  esac

  local jq_filter=".actions |= map(if .id == \"$id\" then .status = \"$new_status\""
  [[ -n "$timestamp_field" ]] && jq_filter+=" | .${timestamp_field} = \"$TIMESTAMP\""
  [[ -n "$field" && -n "$value" ]] && jq_filter+=" | .${field} = \"$value\""
  jq_filter+=" else . end)"

  local tmp
  tmp=$(mktemp)
  jq "$jq_filter" "$QUEUE_FILE" > "$tmp" && mv "$tmp" "$QUEUE_FILE"
  echo "Action $id → $new_status"
}

add_note() {
  local id="$1" note="$2"
  local tmp
  tmp=$(mktemp)
  jq --arg id "$id" --arg note "[$TIMESTAMP] $note" \
    '.actions |= map(if .id == $id then .notes += [$note] else . end)' \
    "$QUEUE_FILE" > "$tmp" && mv "$tmp" "$QUEUE_FILE"
}

# --- Subcommands ---

cmd_add() {
  # Usage: action-queue.sh add --component X --category Y --action-type Z --urgency U --title T --rationale R [--source-report S] [--skill SK] [--params P]
  local component="" category="" action_type="" urgency="" title="" rationale="" source_report="" skill="null" params="{}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --component)     component="$2"; shift 2 ;;
      --category)      category="$2"; shift 2 ;;
      --action-type)   action_type="$2"; shift 2 ;;
      --urgency)       urgency="$2"; shift 2 ;;
      --title)         title="$2"; shift 2 ;;
      --rationale)     rationale="$2"; shift 2 ;;
      --source-report) source_report="$2"; shift 2 ;;
      --skill)         skill="\"$2\""; shift 2 ;;
      --params)        params="$2"; shift 2 ;;
      *) echo "Unknown arg: $1" >&2; return 1 ;;
    esac
  done

  [[ -z "$component" || -z "$action_type" || -z "$title" ]] && {
    echo "Error: --component, --action-type, --title required" >&2; return 1
  }
  [[ -z "$urgency" ]] && urgency="medium"
  [[ -z "$category" ]] && category="tool"

  local id
  id=$(next_id)

  local tmp
  tmp=$(mktemp)
  jq --arg id "$id" \
     --arg comp "$component" \
     --arg cat "$category" \
     --arg at "$action_type" \
     --arg urg "$urgency" \
     --arg title "$title" \
     --arg rat "$rationale" \
     --arg sr "$source_report" \
     --argjson skill "$skill" \
     --argjson params "$params" \
     --arg ts "$TIMESTAMP" \
    '.actions += [{
      id: $id,
      component: $comp,
      category: $cat,
      action_type: $at,
      urgency: $urg,
      title: $title,
      rationale: $rat,
      source_report: $sr,
      created_at: $ts,
      approved_at: null,
      implemented_at: null,
      validated_at: null,
      status: "pending",
      implementation_skill: $skill,
      implementation_params: $params,
      validation_checks: [],
      notes: []
    }]' "$QUEUE_FILE" > "$tmp" && mv "$tmp" "$QUEUE_FILE"

  echo "Created action: $id — $title"
}

cmd_list() {
  local status_filter=""
  local count_only=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status) status_filter="$2"; shift 2 ;;
      --count)  count_only=true; shift ;;
      *) shift ;;
    esac
  done

  local jq_filter=".actions"
  [[ -n "$status_filter" ]] && jq_filter+=" | map(select(.status == \"$status_filter\"))"

  if $count_only; then
    jq "$jq_filter | length" "$QUEUE_FILE"
  else
    jq -r "$jq_filter | .[] | \"[\(.status | ascii_upcase)] \(.id) [\(.urgency)] \(.title) (\(.component))\"" "$QUEUE_FILE"
  fi
}

cmd_approve() {
  local id="$1"
  update_status "$id" "approved"
}

cmd_reject() {
  local id="$1" reason="${2:-No reason given}"
  update_status "$id" "rejected"
  add_note "$id" "Rejected: $reason"
}

cmd_implement() {
  local id="$1"
  update_status "$id" "implementing"
}

cmd_complete() {
  local id="$1"
  update_status "$id" "done"
}

cmd_fail() {
  local id="$1" reason="${2:-}"
  update_status "$id" "failed"
  [[ -n "$reason" ]] && add_note "$id" "Failed: $reason"
}

cmd_dashboard() {
  local pending approved implementing recent
  pending=$(jq -r '.actions[] | select(.status == "pending") | "- **\(.id)** [\(.urgency)] \(.title) (\(.component)) — \(.action_type)"' "$QUEUE_FILE")
  approved=$(jq -r '.actions[] | select(.status == "approved") | "- **\(.id)** [\(.urgency)] \(.title) (\(.component)) — \(.action_type)"' "$QUEUE_FILE")
  implementing=$(jq -r '.actions[] | select(.status == "implementing" or .status == "validating") | "- **\(.id)** [\(.urgency)] \(.title) (\(.component)) — \(.status)"' "$QUEUE_FILE")

  # Recent = done/rejected/failed in last 7 days
  local cutoff
  cutoff=$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "2026-02-19T00:00:00Z")
  recent=$(jq -r --arg cutoff "$cutoff" '.actions[] | select((.status == "done" or .status == "rejected" or .status == "failed") and (.validated_at // .created_at) >= $cutoff) | "- **\(.id)** [\(.status)] \(.title) (\(.component))"' "$QUEUE_FILE")

  cat > "$DASHBOARD_FILE" << DASHEOF
---
title: "Action Queue Dashboard"
type: shared-memory
category: operational
updated: ${TIMESTAMP}
sources: [action-pipeline]
---

# Action Queue Dashboard

Auto-generated from \`action-queue.json\`. Do not edit manually.

## Pending

${pending:-_No pending actions._}

## Approved (ready to implement)

${approved:-_No approved actions._}

## In Progress

${implementing:-_No actions in progress._}

## Recent (last 7 days)

${recent:-_No recent actions._}

---

_Regenerate: \`bash ~/SCRiPTz/action-queue.sh dashboard\`_
DASHEOF

  echo "Dashboard updated: $DASHBOARD_FILE"
  # Also print summary to stdout
  local total pending_count
  total=$(jq '.actions | length' "$QUEUE_FILE")
  pending_count=$(jq '[.actions[] | select(.status == "pending")] | length' "$QUEUE_FILE")
  echo "Total actions: $total | Pending: $pending_count"
}

cmd_notify() {
  local pending_count
  pending_count=$(jq '[.actions[] | select(.status == "pending")] | length' "$QUEUE_FILE")
  [[ "$pending_count" -eq 0 ]] && { echo "No pending actions"; return 0; }

  local summary
  summary=$(jq -r '.actions[] | select(.status == "pending") | "[\(.urgency | ascii_upcase)] \(.title) (\(.component))"' "$QUEUE_FILE")

  local msg="Action Queue: ${pending_count} pending actions
${summary}"

  # Desktop notification
  if command -v notify-send &>/dev/null; then
    notify-send "Action Queue" "$msg" --urgency=normal 2>/dev/null || true
  fi

  # Telegram notification (if configured)
  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${TELEGRAM_CHAT_ID}" \
      -d "text=${msg}" \
      -d "parse_mode=Markdown" >/dev/null 2>&1 || true
  fi

  echo "$msg"
}

# --- Main ---

cmd="${1:-help}"
shift || true

case "$cmd" in
  add)       cmd_add "$@" ;;
  list)      cmd_list "$@" ;;
  approve)   cmd_approve "$@" ;;
  reject)    cmd_reject "$@" ;;
  implement) cmd_implement "$@" ;;
  complete)  cmd_complete "$@" ;;
  fail)      cmd_fail "$@" ;;
  dashboard) cmd_dashboard ;;
  notify)    cmd_notify ;;
  help|*)
    echo "action-queue.sh — Action queue management"
    echo ""
    echo "Subcommands:"
    echo "  add --component X --action-type Y --title Z [--urgency U] [--category C] [--rationale R] [--source-report S] [--skill SK]"
    echo "  list [--status pending|approved|implementing|done|rejected|failed] [--count]"
    echo "  approve <id>"
    echo "  reject <id> [reason]"
    echo "  implement <id>"
    echo "  complete <id>"
    echo "  fail <id> [reason]"
    echo "  dashboard"
    echo "  notify"
    ;;
esac
