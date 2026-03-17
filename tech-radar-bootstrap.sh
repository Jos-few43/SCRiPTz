#!/usr/bin/env bash
# tech-radar-bootstrap.sh — Seed tech-radar.md from live system configs
# Usage: bash tech-radar-bootstrap.sh
set -uo pipefail
# Note: -e intentionally omitted — collectors must be resilient

RADAR_FILE="${HOME}/shared-memory/core/tech-radar.md"
TODAY=$(date -u +%Y-%m-%d)
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# --- Helpers ---

yaml_entry() {
  local name="$1" category="$2" provider="${3:-}" version="${4:-}" status="${5:-adopt}" notes="${6:-}"
  echo "  - name: \"${name}\""
  echo "    category: ${category}"
  [[ -n "$provider" ]] && echo "    provider: ${provider}"
  echo "    status: ${status}"
  [[ -n "$version" ]] && echo "    version: \"${version}\""
  echo "    last_evaluated: ${TODAY}"
  echo "    source_report: null"
  echo "    alternatives: []"
  [[ -n "$notes" ]] && echo "    notes: \"${notes}\""
  [[ -z "$notes" ]] && echo "    notes: \"\""
}

# --- Collect Models from LiteLLM ---

collect_models() {
  local seen=()
  for env in blue green; do
    local config="${HOME}/litellm-stack/${env}/config.yaml"
    [[ -f "$config" ]] || continue
    while IFS= read -r line; do
      local model_name
      model_name=$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*model_name:[[:space:]]*//' | sed 's/^[[:space:]]*model_name:[[:space:]]*//' | tr -d '"' | tr -d "'")
      [[ -z "$model_name" ]] && continue
      # Deduplicate
      local dup=false
      for s in "${seen[@]+"${seen[@]}"}"; do [[ "$s" == "$model_name" ]] && dup=true; done
      $dup && continue
      seen+=("$model_name")
      yaml_entry "$model_name" "model" "" "" "adopt" "instance: ${env}"
    done < <(grep 'model_name:' "$config" 2>/dev/null || true)
  done
}

# --- Collect Containers ---

collect_containers() {
  command -v distrobox &>/dev/null || return 0
  local output
  output=$(distrobox list --no-color 2>/dev/null) || return 0
  while IFS='|' read -r _ name status image _; do
    name=$(echo "$name" | xargs 2>/dev/null) || continue
    status=$(echo "$status" | xargs 2>/dev/null) || continue
    image=$(echo "$image" | xargs 2>/dev/null) || continue
    [[ -z "$name" || "$name" == "NAME" ]] && continue
    local st="adopt"
    [[ "$status" != *"Up"* ]] && st="hold"
    yaml_entry "$name" "container" "distrobox" "" "$st" "image: ${image}"
  done <<< "$output"
}

# --- Collect Claude Code Plugins ---

collect_claude_plugins() {
  local settings="${HOME}/.claude/settings.json"
  [[ -f "$settings" ]] || return 0
  python3 -c "
import json
with open('$settings') as f:
    d = json.load(f)
for p in d.get('enabledPlugins', []):
    print(p)
" 2>/dev/null | while IFS= read -r plugin; do
    plugin=$(echo "$plugin" | xargs 2>/dev/null) || continue
    [[ -z "$plugin" ]] && continue
    yaml_entry "$plugin" "plugin" "claude-code" "" "adopt" ""
  done
}

# --- Collect OpenCode Plugins ---

collect_opencode_plugins() {
  local config="${HOME}/opt-ai-agents/opencode/opencode.json"
  [[ -f "$config" ]] || return 0
  python3 -c "
import json
with open('$config') as f:
    d = json.load(f)
for p in d.get('plugins', []):
    if isinstance(p, str):
        print(p)
    elif isinstance(p, dict):
        print(p.get('name', ''))
" 2>/dev/null | while IFS= read -r plugin; do
    plugin=$(echo "$plugin" | xargs 2>/dev/null) || continue
    [[ -z "$plugin" ]] && continue
    local name="${plugin%%@*}"
    yaml_entry "$name" "plugin" "opencode" "" "adopt" "package: ${plugin}"
  done
}

# --- Collect Skills ---

collect_skills() {
  local skills_dir="${HOME}/shared-skills/source"
  [[ -d "$skills_dir" ]] || return 0
  # Flat skills (*.md)
  for f in "$skills_dir"/*.md; do
    [[ -f "$f" ]] || continue
    local name
    name=$(basename "$f" .md)
    yaml_entry "$name" "skill" "shared-skills" "" "adopt" ""
  done
  # Directory skills (*/SKILL.md)
  for d in "$skills_dir"/*/; do
    [[ -d "$d" && -f "${d}SKILL.md" ]] || continue
    local name
    name=$(basename "$d")
    yaml_entry "$name" "skill" "shared-skills" "" "adopt" "directory-skill"
  done
}

# --- Collect Library Dependencies ---

collect_libraries() {
  local projects_dir="${HOME}/PROJECTz"
  [[ -d "$projects_dir" ]] || return 0
  for proj in "$projects_dir"/*/; do
    [[ -d "$proj" ]] || continue
    local proj_name
    proj_name=$(basename "$proj")
    # package.json (bun/npm)
    if [[ -f "${proj}package.json" ]]; then
      python3 -c "
import json
with open('${proj}package.json') as f:
    d = json.load(f)
for section in ['dependencies', 'devDependencies']:
    for k, v in d.get(section, {}).items():
        print(f'{k}|{v}')
" 2>/dev/null | while IFS='|' read -r pkg ver; do
        [[ -z "$pkg" ]] && continue
        yaml_entry "$pkg" "library" "npm" "$ver" "adopt" "project: ${proj_name}"
      done
    fi
    # requirements.txt (pip)
    if [[ -f "${proj}requirements.txt" ]]; then
      while IFS= read -r line; do
        line=$(echo "$line" | xargs 2>/dev/null) || continue
        [[ -z "$line" || "$line" == \#* ]] && continue
        local pkg ver=""
        if [[ "$line" == *"=="* ]]; then
          pkg="${line%%==*}"
          ver="${line#*==}"
        elif [[ "$line" == *">="* ]]; then
          pkg="${line%%>=*}"
          ver="${line#*>=}+"
        else
          pkg="$line"
        fi
        yaml_entry "$pkg" "library" "pip" "$ver" "adopt" "project: ${proj_name}"
      done < "${proj}requirements.txt"
    fi
  done
}

# --- Assemble Radar ---

generate_radar() {
  cat << HEADER
---
title: "Tech Radar"
type: shared-memory
category: operational
updated: ${TIMESTAMP}
sources: [action-pipeline, bootstrap]
---

# Tech Radar

Component inventory with lifecycle status. Updated by \`tech-radar-bootstrap.sh\` and \`tech-radar-update.sh\`.

Status values: \`adopt\` (active use), \`trial\` (testing), \`assess\` (under evaluation), \`hold\` (paused), \`deprecate\` (phasing out).

## Models

\`\`\`yaml
models:
HEADER
  collect_models
  echo '```'
  echo ""
  echo "## Containers"
  echo ""
  echo '```yaml'
  echo "containers:"
  collect_containers
  echo '```'
  echo ""
  echo "## Tools"
  echo ""
  echo '```yaml'
  echo "tools: []"
  echo '```'
  echo ""
  echo "## Plugins"
  echo ""
  echo '```yaml'
  echo "plugins:"
  collect_claude_plugins
  collect_opencode_plugins
  echo '```'
  echo ""
  echo "## Skills"
  echo ""
  echo '```yaml'
  echo "skills:"
  collect_skills
  echo '```'
  echo ""
  echo "## Libraries"
  echo ""
  echo '```yaml'
  echo "libraries:"
  collect_libraries
  echo '```'
}

# --- Main ---

echo "Bootstrapping tech radar from live system..."
generate_radar > "$RADAR_FILE"
echo "Tech radar written to: $RADAR_FILE"

# Count entries
total=$(grep -c '  - name:' "$RADAR_FILE" 2>/dev/null || echo 0)
echo "Total components inventoried: $total"
