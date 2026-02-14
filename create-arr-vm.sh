#!/bin/bash
# ARR Stack VM Creation Script
# Run this on Proxmox VE (${PROXMOX_HOST})

set -e

VM_NAME="ARR-Stack"
VM_ID="200"
RAM="4096"
CORES="4"
STORAGE="local-lvm"
NET_BRIDGE="vmbr0"

echo "=== Creating ARR Stack VM ==="

# Check if VM exists
if qm list | grep -q "$VM_ID"; then
    echo "VM $VM_ID already exists!"
    exit 0
fi

# Get latest Ubuntu Focal ISO
echo "[1/5] Downloading Ubuntu Cloud Image..."
wget -q https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img -O /var/lib/vz/template/iso/ubuntu-22.04-cloudimg-amd64.img

# Create VM
echo "[2/5] Creating VM..."
qm create $VM_ID \
    --name $VM_NAME \
    --memory $RAM \
    --cores $CORES \
    --cpu host \
    --net0 virtio,bridge=$NET_BRIDGE \
    --scsi0 $STORAGE:0,size=50G \
    --ide2 $STORAGE:cloudinit \
    --boot c \
    --bootdisk scsi0 \
    --ostype l26

# Configure cloud-init
echo "[3/5] Configuring Cloud-Init..."
qm set $VM_ID \
    --ciuser=arr \
    --cipassword=arrstack123 \
    --nameserver=1.1.1.1 \
    --sshkey ~/.ssh/authorized_keys 2>/dev/null || true

# Import disk
echo "[4/5] Importing disk..."
qm importdisk $VM_ID /var/lib/vz/template/iso/ubuntu-22.04-cloudimg-amd64.img $STORAGE --format qcow2

# Attach disk
qm set $VM_ID --scsi0 $STORAGE:$VM_ID/base-2204-disk-0.qcow2

# Enable QEMU Guest Agent
qm set $VM_ID --agent 1

echo "[5/5] VM Created Successfully!"
echo ""
echo "=== Next Steps ==="
echo "1. Start VM: qm start $VM_ID"
echo "2. Wait for cloud-init to complete (~2 minutes)"
echo "3. SSH: ssh arr@$(arp -n | grep $(qm list | grep $VM_ID | awk '{print $3}') | awk '{print $1}')"
echo "4. Or check Proxmox console for IP"
echo ""
echo "=== Then on the VM ==="
echo "ssh arr@<VM_IP>"
echo "sudo -i"
echo "# Install Docker and set up ARR stack"
