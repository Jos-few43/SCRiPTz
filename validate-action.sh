#!/usr/bin/env bash
# validate-action.sh — Run post-implementation health checks for an action
# Usage: validate-action.sh <action-id>
set -uo pipefail

QUEUE_FILE="${HOME}/shared-memory/core/action-queue.json"
QUEUE_SCRIPT="${HOME}/SCRiPTz/action-queue.sh"
CHANGELOG_SCRIPT="${HOME}/SCRiPTz/changelog-update.sh"

log() { echo "[validate] $*"; }

if [[ -z "${1:-}" ]]; then
  echo "Usage: validate-action.sh <action-id>"
  exit 1
fi

ACTION_ID="$1"

# Read action details
ACTION=$(jq --arg id "$ACTION_ID" '.actions[] | select(.id == $id)' "$QUEUE_FILE" 2>/dev/null)
if [[ -z "$ACTION" || "$ACTION" == "null" ]]; then
  log "Error: Action $ACTION_ID not found"
  exit 1
fi

COMPONENT=$(echo "$ACTION" | jq -r '.component')
CATEGORY=$(echo "$ACTION" | jq -r '.category')
STATUS=$(echo "$ACTION" | jq -r '.status')
CHECKS=$(echo "$ACTION" | jq -r '.validation_checks[]?' 2>/dev/null)

log "Validating action $ACTION_ID ($COMPONENT)"
log "Category: $CATEGORY | Status: $STATUS"

# Update status to validating
bash "$QUEUE_SCRIPT" implement "$ACTION_ID" 2>/dev/null || true

PASS=0
FAIL=0
TOTAL=0

# --- Check functions ---

check_litellm_health() {
  log "Check: LiteLLM health endpoints"
  local all_ok=true
  for port in 4000 4001 4002; do
    local result
    result=$(curl -s --max-time 5 "http://localhost:${port}/health" 2>/dev/null) || true
    if echo "$result" | jq -e '.status' &>/dev/null 2>&1; then
      log "  Port $port: OK"
    else
      log "  Port $port: FAIL (unreachable or unhealthy)"
      all_ok=false
    fi
  done
  $all_ok && return 0 || return 1
}

check_container_status() {
  log "Check: Container status"
  if ! command -v distrobox &>/dev/null; then
    log "  distrobox not available"
    return 1
  fi
  local target_container=""
  # Try to match component to a known container
  if distrobox list --no-color 2>/dev/null | grep -qi "$COMPONENT"; then
    log "  Container '$COMPONENT': found"
    if distrobox list --no-color 2>/dev/null | grep -i "$COMPONENT" | grep -qi "up\|running"; then
      log "  Status: running"
      return 0
    else
      log "  Status: not running"
      return 1
    fi
  else
    log "  Component '$COMPONENT' is not a container — skipping"
    return 0
  fi
}

check_model_response() {
  log "Check: Model response test"
  # Try to get a completion from the model via LiteLLM
  local response
  for port in 4001 4002; do
    response=$(curl -s --max-time 15 "http://localhost:${port}/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${LITELLM_API_KEY:-sk-placeholder}" \
      -d "{\"model\": \"$COMPONENT\", \"messages\": [{\"role\": \"user\", \"content\": \"Say hello\"}], \"max_tokens\": 10}" \
      2>/dev/null) || continue
    if echo "$response" | jq -e '.choices[0].message.content' &>/dev/null 2>&1; then
      log "  Model '$COMPONENT' responded on port $port"
      return 0
    fi
  done
  log "  Model '$COMPONENT' did not respond on any port"
  return 1
}

check_plugin_load() {
  log "Check: Plugin load test"
  # Verify plugin appears in settings
  if [[ -f "$HOME/.claude/settings.json" ]]; then
    if jq -e ".enabledPlugins[] | select(. == \"$COMPONENT\")" "$HOME/.claude/settings.json" &>/dev/null; then
      log "  Plugin '$COMPONENT' found in Claude Code settings"
      return 0
    fi
  fi
  if [[ -f "$HOME/opt-ai-agents/opencode/opencode.json" ]]; then
    if jq -e ".plugins[] | select(. == \"$COMPONENT\" or startswith(\"$COMPONENT\"))" "$HOME/opt-ai-agents/opencode/opencode.json" &>/dev/null 2>&1; then
      log "  Plugin '$COMPONENT' found in OpenCode config"
      return 0
    fi
  fi
  log "  Plugin '$COMPONENT' not found in any tool config"
  return 1
}

check_config_syntax() {
  log "Check: Config syntax validation"
  local ok=true
  # Validate key config files
  for config in "$HOME/litellm-stack/blue/config.yaml" "$HOME/litellm-stack/green/config.yaml"; do
    if [[ -f "$config" ]]; then
      if python3 -c "import yaml; yaml.safe_load(open('$config'))" 2>/dev/null; then
        log "  $(basename "$(dirname "$config")")/config.yaml: valid YAML"
      else
        log "  $(basename "$(dirname "$config")")/config.yaml: INVALID YAML"
        ok=false
      fi
    fi
  done
  for config in "$HOME/.claude/settings.json" "$HOME/opt-ai-agents/opencode/opencode.json"; do
    if [[ -f "$config" ]]; then
      if jq . "$config" > /dev/null 2>&1; then
        log "  $(basename "$config"): valid JSON"
      else
        log "  $(basename "$config"): INVALID JSON"
        ok=false
      fi
    fi
  done
  $ok && return 0 || return 1
}

check_port() {
  log "Check: Port bindings"
  local ports_to_check=(4000 4001 4002)
  local ok=true
  for port in "${ports_to_check[@]}"; do
    if curl -s --max-time 3 "http://localhost:${port}" &>/dev/null; then
      log "  Port $port: listening"
    else
      log "  Port $port: not listening"
      # Only fail if this is a LiteLLM-related action
      [[ "$CATEGORY" == "model" ]] && ok=false
    fi
  done
  $ok && return 0 || return 1
}

# --- Determine which checks to run ---

# If action has explicit validation_checks, use those
if [[ -n "$CHECKS" ]]; then
  while IFS= read -r check; do
    [[ -z "$check" ]] && continue
    TOTAL=$((TOTAL + 1))
    case "$check" in
      litellm-health)      check_litellm_health && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1)) ;;
      container-status)    check_container_status && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1)) ;;
      model-response-test) check_model_response && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1)) ;;
      plugin-load-test)    check_plugin_load && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1)) ;;
      config-syntax)       check_config_syntax && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1)) ;;
      port-check)          check_port && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1)) ;;
      *) log "Unknown check: $check"; FAIL=$((FAIL + 1)) ;;
    esac
  done <<< "$CHECKS"
else
  # Auto-determine checks based on category
  case "$CATEGORY" in
    model)
      TOTAL=3
      check_config_syntax && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))
      check_litellm_health && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))
      check_model_response && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))
      ;;
    container)
      TOTAL=1
      check_container_status && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))
      ;;
    plugin)
      TOTAL=2
      check_config_syntax && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))
      check_plugin_load && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))
      ;;
    *)
      TOTAL=1
      check_config_syntax && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))
      ;;
  esac
fi

# --- Report results ---

log ""
log "Results: $PASS/$TOTAL passed, $FAIL failed"

if [[ $FAIL -eq 0 ]]; then
  log "VALIDATION PASSED"
  bash "$QUEUE_SCRIPT" complete "$ACTION_ID" 2>/dev/null
  # Trigger changelog update
  if [[ -f "$CHANGELOG_SCRIPT" ]]; then
    bash "$CHANGELOG_SCRIPT" "$ACTION_ID" 2>&1 || true
  fi
  # Notify
  if command -v notify-send &>/dev/null; then
    notify-send "Action Validated" "$ACTION_ID: $COMPONENT — all checks passed" 2>/dev/null || true
  fi
else
  log "VALIDATION FAILED"
  bash "$QUEUE_SCRIPT" fail "$ACTION_ID" "$FAIL/$TOTAL checks failed" 2>/dev/null
  if command -v notify-send &>/dev/null; then
    notify-send --urgency=critical "Action Failed" "$ACTION_ID: $COMPONENT — $FAIL checks failed" 2>/dev/null || true
  fi
fi
