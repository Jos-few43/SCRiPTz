#!/usr/bin/env bash
set -euo pipefail

echo "🔍 Remote Access Test for OpenCode"
echo "=================================="
echo ""

echo "Your Tailscale Details:"
echo "  Tailscale IPv4: 100.112.141.3"
echo "  MagicDNS Name:  bazzite.tail8be4f7.ts.net"
echo ""

echo "📡 Test SSH Access (from remote device):"
echo "  ssh yish@bazzite.tail8be4f7.ts.net"
echo "  tailscale ssh bazzite"
echo ""

echo "🌐 Test Web Access (from any Tailscale device):"
echo "  OpenCode Frontend:  http://bazzite.tail8be4f7.ts.net:5173"
echo "  OpenCode Backend:   http://bazzite.tail8be4f7.ts.net:5003"
echo "  OpenCode Server:    http://bazzite.tail8be4f7.ts.net:5551"
echo ""

echo "🚀 Start OpenCode Development Server (run this first):"
echo "  distrobox enter opencode-dev -- bash -c 'cd ~/opencode-manager && pnpm dev'"
echo ""

echo "✅ Checking if development servers are running..."
if curl -s -o /dev/null -w "%{http_code}" http://localhost:5173 | grep -q 200; then
  echo "  ✅ Frontend is running on port 5173"
else
  echo "  ⚠️  Frontend not running (start with 'pnpm dev')"
fi

if curl -s -o /dev/null -w "%{http_code}" http://localhost:5003 | grep -q 200; then
  echo "  ✅ Backend is running on port 5003"
else
  echo "  ⚠️  Backend not running (start with 'pnpm dev')"
fi

echo ""
echo "📱 Mobile Access: Use Termius or Safari with the URLs above"
echo "💻 Desktop Access: SSH or web browser to the addresses above"
