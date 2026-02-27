# AGENTS.md

Guidelines for AI coding agents working in SCRiPTz.

## Overview

Collection of ~33 Bash utility scripts (~3,150 LOC) for vault analysis, deep research, link ingestion, agent launching, and infrastructure automation.

## Commands

```bash
bash vault-gap-scanner.sh                    # Scan vault for gaps
bash run-deep-research.sh [max_topics]       # Run deep research pipeline
bash sync-claude-to-vault.sh                 # Sync Claude sessions to vault
bash link-classifier.sh "URL"                # Classify a URL
bash link-ingest.sh "URL" cli               # Ingest a URL to vault
python3 local-agent.py "task"               # Run local Ollama agent
bash launch-opencode.sh                     # Launch OpenCode in container
```

## Code Style

- Bash: Strict mode (`set -euo pipefail`) in all scripts
- Use `$HOME` or `${HOME}`, never hardcode `~`
- Large prompts via stdin pipe (not CLI args — ARG_MAX limits)
- ShellCheck compliant

## File Structure

- Core: `run-deep-research.sh`, `vault-gap-scanner.sh`, `vault-research-postprocess.sh`
- Integration: `sync-claude-to-vault.sh`, `claude-via-proxy.sh`
- Link pipeline: `link-classifier.sh`, `link-ingest.sh`, `link-batch-processor.sh`
- Agents: `launch-*.sh`, `gemini-research.sh`, `local-agent.py`
- Infrastructure: `proxmox-*.sh`, `start-lmstudio.sh`

## Anti-patterns

- Don't pass large prompts via CLI args — use stdin pipe
- Don't run without vault at `$VAULT_PATH`
- Don't hardcode `~` in hook scripts
- Don't edit `n8n-*.json` by hand

## Agent Council

| Agent | Model | Role | Use When |
|---|---|---|---|
| sisyphus | claude-opus-4-6-thinking | Orchestrator | Script creation, multi-step automation |
| prometheus | gemini-3-pro-high | Analyzer | Script design, pipeline planning |
| explore | gemini-3-flash | Search | Finding scripts, checking patterns |
