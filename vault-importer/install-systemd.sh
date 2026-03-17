#!/bin/bash
# Install vault-importer systemd user units
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYSTEMD_DIR="$HOME/.config/systemd/user"

mkdir -p "$SYSTEMD_DIR"

# Copy units
cp "$SCRIPT_DIR/systemd/vault-importer.service" "$SYSTEMD_DIR/"
cp "$SCRIPT_DIR/systemd/vault-importer-sync.service" "$SYSTEMD_DIR/"
cp "$SCRIPT_DIR/systemd/vault-importer.timer" "$SYSTEMD_DIR/"

# Reload and enable
systemctl --user daemon-reload
systemctl --user enable --now vault-importer.timer

echo "✅ vault-importer.timer enabled (hourly sync)"
echo ""
echo "To also run the persistent watcher:"
echo "  systemctl --user enable --now vault-importer.service"
echo ""
echo "Check status:"
echo "  systemctl --user status vault-importer.timer"
echo "  systemctl --user status vault-importer.service"
echo "  journalctl --user -u vault-importer -f"
