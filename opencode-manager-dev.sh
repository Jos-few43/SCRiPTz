#!/usr/bin/env bash
set -euo pipefail

echo "🚀 Launching OpenCode Manager development environment..."
echo ""

# Enter container and navigate to project
distrobox enter opencode-dev -- bash -c '
  cd ~/workspace/opencode-projects/opencode-manager || {
    echo "❌ Project not found. Cloning..."
    mkdir -p ~/workspace/opencode-projects
    cd ~/workspace/opencode-projects
    echo "Please clone your repository manually:"
    echo "  git clone <your-repo-url> opencode-manager"
    exit 1
  }

  echo "📂 Working directory: $(pwd)"
  echo ""
  echo "Available commands:"
  echo "  pnpm dev          - Start development servers"
  echo "  pnpm build        - Build all packages"
  echo "  pnpm test         - Run tests"
  echo "  opencode          - Launch OpenCode AI agent"
  echo ""

  # Start an interactive bash shell
  exec bash
'
