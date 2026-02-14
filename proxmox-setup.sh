#!/bin/bash
# Proxmox OpenCode Setup Script
# Copy this to your Proxmox server and run as root

echo "=== Proxmox OpenCode Setup ==="
echo ""

# Create user if doesn't exist
if ! pveum user list | grep -q "opencode@pam"; then
    echo "Creating opencode user..."
    pveum useradd opencode@pam --comment "OpenCode Manager"
    echo "✓ User created"
else
    echo "✓ opencode user already exists"
fi

# Set password
echo ""
echo "Setting password for opencode@pam..."
pveum passwd opencode@pam

# Grant permissions
echo ""
echo "Granting Admin permissions to opencode@pam..."
pveum aclmod / -user opencode@pam -role Admin
echo "✓ Admin permissions granted"

# Setup SSH
echo ""
echo "Setting up SSH key authentication..."

# Create user home directory if it doesn't exist
if [ ! -d "/home/opencode" ]; then
    mkdir -p /home/opencode
    chown opencode:opencode /home/opencode
fi

mkdir -p /home/opencode/.ssh
chmod 700 /home/opencode/.ssh

cat > /home/opencode/.ssh/authorized_keys << 'SSHPUBKEY'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE1i1iJ7yFvn+I8J0W0/Ri4l4zZLnYrrTrMIFBTx0t5m opencode@proxmox-20250208
SSHPUBKEY

chmod 600 /home/opencode/.ssh/authorized_keys
chown -R opencode:opencode /home/opencode/.ssh
echo "✓ SSH key added"

# SSH hardening config
echo ""
echo "Configuring SSH..."
cat > /etc/ssh/sshd_config.d/opencode.conf << 'EOF'
# OpenCode SSH Configuration
PubkeyAuthentication yes
PasswordAuthentication no
PermitRootLogin prohibit-password
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

systemctl restart sshd
echo "✓ SSH configured"

# Set proper shell
echo ""
echo "Setting up user shell..."
usermod -s /bin/bash opencode 2>/dev/null || true

echo ""
echo "============================================"
echo "✅ Setup Complete!"
echo "============================================"
echo ""
echo "Next Steps:"
echo "------------"
echo "1. Open browser: https://${PROXMOX_HOST}:8006"
echo "2. Login as root"
echo "3. Go to: Datacenter → Permissions → API Tokens"
echo "4. Click 'Add' and create token for:"
echo "   - User: opencode@pam"
echo "   - Token ID: opencode-token"
echo "   - Uncheck 'Privilege Separation'"
echo "5. COPY THE TOKEN SECRET (only shown once!)"
echo ""
echo "Test SSH Access:"
echo "  ssh -i ~/.ssh/proxmox_opencode opencode@${PROXMOX_HOST}"
echo ""
echo "API Token Format:"
echo "  ID: opencode@pam!opencode-token"
echo "  Secret: [the secret you copied]"
echo ""
