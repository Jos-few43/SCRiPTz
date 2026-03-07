#!/bin/bash
# Run this ON PROXMOX SERVER (SSH or Console)

echo "=== PROXMOX MANUAL SETUP FOR OPENCODE ==="
echo ""

# Add SSH key
echo "[1/4] Adding SSH key..."
mkdir -p /home/opencode/.ssh
chmod 700 /home/opencode/.ssh
cat > /home/opencode/.ssh/authorized_keys << 'EOF'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIECweeFVUoigo39p1gV5UTY9M+r/y7TwW5w8IfVPZkmb opencode@proxmox-20260208
EOF
chmod 600 /home/opencode/.ssh/authorized_keys
chown -R opencode:opencode /home/opencode/.ssh

# Create user
echo "[2/4] Creating opencode user..."
useradd -m opencode 2>/dev/null || true
echo "opencode:asdfghjkl;" | chpasswd

# Add to Proxmox
echo "[3/4] Setting Proxmox permissions..."
pveum useradd opencode@pam 2>/dev/null || echo "User may exist"
pveum aclmod / -user opencode@pam -role PVEAdmin 2>/dev/null || pveum acl add / -user opencode@pam -role PVEAdmin

# Test SSH
echo "[4/4] Testing SSH..."
ssh opencode@localhost "echo SSH SUCCESS!" 2>/dev/null || echo "SSH test skipped"

echo ""
echo "=== DONE ==="
echo ""
echo "NEXT: Create API Token in Proxmox UI"
echo "1. https://${PROXMOX_HOST:-<your-proxmox-ip>}:8006"
echo "2. Datacenter → Permissions → API Tokens"
echo "3. Add Token:"
echo "   User: opencode@pam"
echo "   Token ID: opencode-token"
echo "   Uncheck Privilege Separation"
echo "4. COPY THE SECRET"
