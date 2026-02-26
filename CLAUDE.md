# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A collection of ~33 production scripts (~3,150 LOC) serving as the operational glue layer between Claude Code, OpenClaw-Vault (Obsidian), OpenCode/OpenClaw agents, Proxmox, n8n, Gemini CLI, LM Studio, and Telegram. Implements three major automation pipelines: research generation, session logging, and link ingestion.

## Tech Stack

| Component | Technology |
|---|---|
| Primary | Bash (24 scripts, ~2,200 LOC), strict mode (`set -euo pipefail`) |
| Secondary | Python 3 (local-agent.py, 227 LOC — Ollama function calling) |
| Data interchange | JSON (jq for processing) |
| HTTP | curl (Telegram API, HTTP POST) |
| Containers | distrobox (Gemini, OpenCode, LSP servers) |
| AI CLIs | `claude --print` (headless), Gemini CLI, Ollama |

## Project Structure

```
SCRiPTz/
├── Core Pipeline (Research Automation)
│   ├── run-deep-research.sh          # Main orchestrator (n8n daily 3AM trigger)
│   ├── vault-gap-scanner.sh          # Scan vault for knowledge gaps via wikilinks
│   ├── vault-research-postprocess.sh # Integrate reports into vault MOCs
│   ├── vault-research-autoprocess.sh # Auto-categorize by keyword matching
│   └── research-config.json          # Quality gates, notification toggles
│
├── Claude Code Integration
│   ├── sync-claude-to-vault.sh       # SessionEnd hook: transcripts → Obsidian notes
│   ├── backfill-claude-logs.sh       # Backfill historical transcripts
│   └── claude-via-proxy.sh           # Route through LiteLLM (port 4000 fallback)
│
├── Link Ingestion Pipeline
│   ├── link-classifier.sh            # Pattern-based URL classification
│   ├── link-ingest.sh                # Classify → stub → queue
│   ├── link-batch-processor.sh       # Async deep analysis of queued links
│   └── telegram-ingest-handler.sh    # Telegram webhook handler
│
├── AI Agent Launchers
│   ├── launch-opencode.sh            # Enter opencode-dev distrobox
│   ├── launch-openclaw.sh            # Enter openclaw-dev + OAuth token sync
│   ├── gemini-research.sh            # Delegate research to Gemini (headless)
│   ├── local-agent.py                # Ollama + function calling agent
│   ├── local-delegate.sh             # Delegate to local agent
│   └── sync-anthropic-token.sh       # Sync OAuth: Claude → OpenClaw
│
├── Infrastructure
│   ├── proxmox-setup.sh              # Setup Proxmox user, perms, SSH
│   ├── proxmox-manager.sh            # VM lifecycle (create, destroy, list, ssh)
│   ├── create-arr-vm.sh              # ARR media stack VM creation
│   └── start-lmstudio.sh            # LM Studio startup wrapper
│
├── Development Tooling
│   ├── lsp-wrappers/                 # LSP servers routed through distrobox containers
│   │   └── typescript-lsp.sh, pyright-lsp.sh, rust-analyzer-lsp.sh, gopls-lsp.sh
│   ├── opencode-manager-dev.sh       # Dev mode launcher
│   └── install-warp.sh              # Warp Terminal installer
│
├── Workflow Orchestration
│   └── n8n-deep-research-workflow.json  # Daily 3AM trigger + error logging
│
└── Templates
    ├── research-report-template.md    # 8-section report schema
    └── research-system-prompt.md      # System prompt for headless Claude
```

## Key Commands

```bash
# Research pipeline
bash vault-gap-scanner.sh                    # Scan for knowledge gaps (JSON output)
bash run-deep-research.sh [max_topics]       # Full pipeline (default: 3 topics)

# Claude session sync
echo '{"session_id":"...","transcript_path":"..."}' | bash sync-claude-to-vault.sh

# Link ingestion
bash link-classifier.sh "https://arxiv.org/abs/..."    # Classify URL
bash link-ingest.sh "https://..." cli                   # Ingest + queue
bash link-batch-processor.sh [max_items]                # Process queue

# Agent launchers
bash launch-opencode.sh                      # Enter opencode-dev container
bash launch-openclaw.sh                      # Enter openclaw-dev + sync token
bash gemini-research.sh -m gemini-2.5-pro "query"  # Headless Gemini
python3 local-agent.py "task description"    # Ollama local agent

# Token sync
bash sync-anthropic-token.sh --watch         # Continuous: Claude → OpenClaw
```

## Architecture

### Research Pipeline (scheduled via n8n at 3AM)

```
vault-gap-scanner.sh → JSON gaps
  → for each gap:
      echo "$PROMPT" | claude --print  (stdin pipe, avoids ARG_MAX)
      → vault-research-postprocess.sh (link into MOC, frontmatter, commit)
```

### Session Logging (Claude Code SessionEnd hook)

```
sync-claude-to-vault.sh (JSON stdin)
  → Parse JSONL transcript
  → Create session note + update MOC + daily note
  → Extract tasks → plan document
  → Extract memory (bun memory-extractor)
  → Sync to shared-memory (ingest.sh)
```

### Link Ingestion (Telegram + CLI)

```
URL → link-classifier.sh → type (paper, repo, model, ...)
  → link-ingest.sh → inbox stub + queue
  → link-batch-processor.sh → deep analysis → vault research note
```

## Configuration

| Variable | Used By | Purpose |
|---|---|---|
| `VAULT_PATH` | Research pipeline | Vault root dir (default: `$HOME/Documents/OpenClaw-Vault`) |
| `TELEGRAM_BOT_TOKEN` | Notifications | Telegram bot auth (optional) |
| `TELEGRAM_CHAT_ID` | Notifications | Target chat (optional) |
| `OLLAMA_URL` | local-agent.py | Ollama endpoint (default: localhost:11434) |

**Config file**: `research-config.json` — quality gates (P1: 800 lines, P2: 500, P3: 300), notification toggles, vault path.

## Cross-Repo Relationships

- **OpenClaw-Vault** (`~/Documents/OpenClaw-Vault/`) — Read gaps, write reports/sessions
- **shared-skills** (`~/shared-skills/`) — Referenced in skill sync
- **shared-memory** (`~/shared-memory/`) — Memory ingestion target
- **litellm-stack** — Claude proxy routing (port 4000)
- **distrobox containers** — opencode-dev, openclaw-dev, ai-cli-tools-dev, dev-tools

## Things to Avoid

- Don't pass large prompts via CLI args — use stdin pipe (ARG_MAX limits)
- Don't run research scripts without the vault existing at `$VAULT_PATH`
- Don't forget to register `sync-claude-to-vault.sh` as a SessionEnd hook
- Don't assume containers are running — scripts check but don't create them
- Don't hardcode `~` in scripts run by hooks — use `${HOME}` or `$HOME`
- Don't edit `n8n-deep-research-workflow.json` by hand — use n8n UI when possible
