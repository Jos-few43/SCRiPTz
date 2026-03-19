# SCRiPTz

Operational glue layer for research automation, vault integration, and AI agent orchestration. ~33 scripts (~3,150 LOC) connecting Claude Code, OpenClaw-Vault (Obsidian), OpenCode/OpenClaw agents, Proxmox, n8n, Gemini CLI, and Telegram.

## Quick Start

**Prerequisites**

- Bazzite / immutable Fedora Atomic host with distrobox
- [Bun](https://bun.sh/) (for vault-importer — never install Node directly on host)
- `jq`, `curl` available in your container
- OpenClaw-Vault at `$VAULT_PATH` (default: `$HOME/Documents/OpenClaw-Vault`)

**Setup**

```bash
git clone https://github.com/Jos-few43/SCRiPTz.git ~/SCRiPTz
cd ~/SCRiPTz/vault-importer && bun install

# Set required env vars (see table below or use ~/secrets/ store)
export VAULT_PATH="$HOME/Documents/OpenClaw-Vault"
```

**Basic usage**

```bash
bash run-deep-research.sh 3                   # Research pipeline (3 topics)
bash link-ingest.sh "https://arxiv.org/..." cli   # Ingest a URL
echo '{"session_id":"..."}' | bash sync-claude-to-vault.sh  # Sync session
cd vault-importer && bun run sync             # Sync/transform vault content
```

## Script Categories

### Research Pipeline

| Script | Description |
|---|---|
| `run-deep-research.sh` | Main orchestrator — scans gaps, runs headless Claude, integrates reports. Triggered daily at 3AM via n8n. |
| `vault-gap-scanner.sh` | Scans vault wikilinks for unresolved knowledge gaps; outputs JSON. |
| `vault-research-postprocess.sh` | Links generated reports into vault MOCs, sets frontmatter, commits. |
| `vault-research-autoprocess.sh` | Auto-categorizes reports by keyword matching. |

### Claude Code Integration

| Script | Description |
|---|---|
| `sync-claude-to-vault.sh` | SessionEnd hook: parses JSONL transcripts → Obsidian session notes, daily notes, task plans, memory extraction. |
| `sync-anthropic-token.sh` | Syncs Claude OAuth token to OpenClaw container (`--watch` for continuous). |
| `backfill-claude-logs.sh` | Backfills historical Claude transcripts into the vault. |

### Link Ingestion

| Script | Description |
|---|---|
| `link-classifier.sh` | Pattern-based URL classifier (paper, repo, model, article, ...). |
| `link-ingest.sh` | Classify → create inbox stub → queue for deep analysis. |
| `link-batch-processor.sh` | Async deep analysis of queued links; writes vault research notes. |
| `telegram-ingest-handler.sh` | Telegram webhook handler — routes URLs from chat into the ingestion pipeline. |

### AI Agents

| Script | Description |
|---|---|
| `local-agent.py` | Ollama-backed function-calling agent (Python, 227 LOC). |
| `local-delegate.sh` | Shell wrapper to delegate tasks to the local Ollama agent. |
| `gemini-research.sh` | Headless Gemini CLI research delegation (`-m gemini-2.5-pro`). |
| `tmux-agents.sh` | Launch and manage multi-agent tmux sessions. |

### Infrastructure

| Script | Description |
|---|---|
| `proxmox-setup.sh` | Initial Proxmox user, permissions, and SSH configuration. |
| `proxmox-manager.sh` | VM lifecycle management: create, destroy, list, ssh. |

### Vault Importer (`vault-importer/`)

TypeScript/Bun tool for importing, transforming, and maintaining Obsidian vault content.

```bash
cd vault-importer
bun run sync          # Full sync
bun run watch         # File watcher mode
bun run dry-run       # Preview changes without writing
bun run orphans       # Find orphaned notes
bun run migrate       # Tag migration
bun run link-chains   # Resolve link chains
bun run commands      # Sync custom commands
```

Key modules: `transformer.ts`, `linker.ts`, `chain-linker.ts`, `tag-migrator.ts`, `memory-extractor.ts`, `redactor.ts`, `litellm.ts`.

## Environment Variables

| Variable | Default | Used By |
|---|---|---|
| `VAULT_PATH` | `$HOME/Documents/OpenClaw-Vault` | Research pipeline, sync scripts |
| `OLLAMA_URL` | `http://localhost:11434` | `local-agent.py` |
| `LITELLM_ROOT` | `$HOME/litellm-stack` | `claude-via-proxy.sh` |
| `TELEGRAM_BOT_TOKEN` | — | `telegram-ingest-handler.sh`, notifications |
| `TELEGRAM_CHAT_ID` | — | Notification target |
| `ANTHROPIC_API_KEY` | — | Headless Claude calls |
| `GEMINI_API_KEY` | — | `gemini-research.sh` |

Secrets are managed via `~/secrets/` (SOPS+age). Never edit `.env` files directly — use `secrets set` then `secrets inject`.

Config overrides: `research-config.json` — quality gates (P1: 800 lines, P2: 500, P3: 300), notification toggles, vault path.

For development guidance, container setup, and architecture details, see [CLAUDE.md](CLAUDE.md).

## License

MIT — see [LICENSE](LICENSE).
