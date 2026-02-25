#!/usr/bin/env bash
set -euo pipefail

# vault-research-autoprocess.sh — Automatically detect theme/title from a
# research report and run the vault post-processor.
#
# Usage:
#   bash vault-research-autoprocess.sh <report-path>
#
# Called automatically by PostToolUse hook when a Write lands in
# ~/.openclaw/workspace/memory/research/reports/

REPORT_PATH="$1"
SLUG="$(basename "$REPORT_PATH" .md)"
DATE="$(date +%Y-%m-%d)"

WORKSPACE="$HOME/.openclaw/workspace/memory/research/reports"
VAULT="$HOME/Documents/OpenClaw-Vault"
POSTPROCESS="$HOME/SCRiPTz/vault-research-postprocess.sh"

###############################################################################
# Guard: only process files in the research reports directory
###############################################################################

if [[ ! "$REPORT_PATH" == *"memory/research/reports/"* ]]; then
  exit 0
fi

if [[ ! -f "$REPORT_PATH" ]]; then
  echo "[autoprocess] Report not found: $REPORT_PATH" >&2
  exit 0
fi

# Skip if already in vault (avoid re-processing copies)
if [[ "$REPORT_PATH" == *"OpenClaw-Vault"* ]]; then
  exit 0
fi

###############################################################################
# Auto-detect title from first H1 heading
###############################################################################

TITLE=""
while IFS= read -r line; do
  if [[ "$line" =~ ^#\ (.+) ]]; then
    TITLE="${BASH_REMATCH[1]}"
    break
  fi
done < "$REPORT_PATH"

if [[ -z "$TITLE" ]]; then
  # Fallback: derive from slug
  TITLE="$(echo "$SLUG" | sed 's/_/ /g; s/\b\(.\)/\u\1/g')"
fi

###############################################################################
# Auto-detect theme from Tags line or content heuristics
###############################################################################

THEME="General"

# Gather signals: Tags (plain or bold), Stack Relevance, Scope, Key References, title
TAGS_LINE="$(grep -m1 -iE '^\*?\*?Tags:' "$REPORT_PATH" 2>/dev/null || true)"
STACK_LINE="$(grep -m1 -i 'Stack Relevance:' "$REPORT_PATH" 2>/dev/null || true)"
SCOPE_LINE="$(grep -m1 -i 'Scope:' "$REPORT_PATH" 2>/dev/null || true)"
REFS_LINE="$(grep -m1 -i 'Key References:' "$REPORT_PATH" 2>/dev/null || true)"

COMBINED="$TAGS_LINE $STACK_LINE $SCOPE_LINE $REFS_LINE $TITLE"

# Theme detection — use Scope + Tags + Title (exclude Stack Relevance to avoid
# false matches on the ubiquitous "OpenClaw / CORTEX / SUPRA / Bazzite / Infra")
DETECT="$TAGS_LINE $SCOPE_LINE $REFS_LINE $TITLE"

if echo "$DETECT" | grep -qiE 'safety|alignment|guardrail|mi9|containment|jailbreak|drift|regression'; then
  THEME="AI-Safety"
elif echo "$DETECT" | grep -qiE 'token.efficien|quantiz|distill|compress|speculative|pruning'; then
  THEME="Token-Efficiency"
elif echo "$DETECT" | grep -qiE 'infrastructure|kubernetes|k8s|docker|podman|terraform|nixos|networking'; then
  THEME="Infrastructure"
elif echo "$DETECT" | grep -qiE 'local.model|gguf|ollama|vram|lmstudio|fine.tun'; then
  THEME="Local-Models"
fi

###############################################################################
# Copy report to vault theme directory
###############################################################################

VAULT_THEME_DIR="$VAULT/01-RESEARCH/$THEME"
mkdir -p "$VAULT_THEME_DIR"

VAULT_REPORT="$VAULT_THEME_DIR/$SLUG.md"

if [[ -f "$VAULT_REPORT" ]]; then
  # Check if content changed (avoid no-op copies)
  if cmp -s "$REPORT_PATH" "$VAULT_REPORT" 2>/dev/null; then
    echo "[autoprocess] No changes detected — skipping"
    exit 0
  fi
fi

cp "$REPORT_PATH" "$VAULT_REPORT"
echo "[autoprocess] Copied to $VAULT_REPORT"

###############################################################################
# Run the full post-processor
###############################################################################

if [[ -x "$POSTPROCESS" ]] || [[ -f "$POSTPROCESS" ]]; then
  bash "$POSTPROCESS" "$VAULT_REPORT" "$THEME" "$TITLE" "$DATE"
else
  echo "[autoprocess] Post-processor not found: $POSTPROCESS" >&2
  exit 0
fi
