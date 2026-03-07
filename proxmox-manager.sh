#!/bin/bash
# Proxmox Manager - API-based management

TOKEN_ID="${PROXMOX_TOKEN_ID:-opencode@pam!opencode-token}"
TOKEN_SECRET="${PROXMOX_TOKEN_SECRET:?PROXMOX_TOKEN_SECRET env var is required}"
API_URL="https://${PROXMOX_HOST:-${PROXMOX_HOST}}:8006"

api_call() {
    curl -k -H "Authorization: PVEAPIToken=$TOKEN_ID=$TOKEN_SECRET" \
        "$API_URL/api2/json$1" 2>/dev/null
}

case "$1" in
    list)
        echo "=== VMs ==="
        api_call "/nodes/localhost/qemu" | python3 -m json.tool 2>/dev/null | grep -A5 '"vmid"'
        echo ""
        echo "=== Containers ==="
        api_call "/nodes/localhost/lxc" | python3 -m json.tool 2>/dev/null | grep -A5 '"vmid"'
        ;;
    status)
        api_call "/nodes/localhost/status" | python3 -m json.tool
        ;;
    storage)
        api_call "/storage" | python3 -m json.tool
        ;;
    resources)
        api_call "/cluster/resources" | python3 -m json.tool
        ;;
    startvm)
        api_call "/nodes/localhost/qemu/$2/status/start" -X POST
        echo "Starting VM $2..."
        ;;
    stopvm)
        api_call "/nodes/localhost/qemu/$2/status/stop" -X POST
        echo "Stopping VM $2..."
        ;;
    rebootvm)
        api_call "/nodes/localhost/qemu/$2/status/reboot" -X POST
        echo "Rebooting VM $2..."
        ;;
    vminfo)
        api_call "/nodes/localhost/qemu/$2/config" | python3 -m json.tool
        ;;
    *)
        echo "Usage: $0 {list|status|storage|resources|startvm <id>|stopvm <id>|rebootvm <id>|vminfo <id>}"
        ;;
esac
