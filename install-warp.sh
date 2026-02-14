#!/bin/bash

# Configuration Variables
CONTAINER_NAME="warp-term"
# We use Fedora because Bazzite is Fedora-based, ensuring best driver/clipboard compatibility
IMAGE_NAME="registry.fedoraproject.org/fedora:41" 
APP_NAME="warp-terminal"

echo "### Bazzite Warp Terminal Installer ###"
echo "Target Container: $CONTAINER_NAME"
echo "Base Image: $IMAGE_NAME"
echo "---------------------------------------"

# 1. Create the Distrobox container if it doesn't exist
if distrobox list | grep -q "$CONTAINER_NAME"; then
    echo "[!] Container '$CONTAINER_NAME' already exists. Skipping creation."
else
    echo "[+] Creating Distrobox container..."
    # --pull ensures we get the latest updates for the image
    distrobox create --name "$CONTAINER_NAME" --image "$IMAGE_NAME" --pull --yes
fi

# 2. Install Warp Terminal inside the container
echo "[+] Installing Warp Terminal dependencies and package..."
distrobox enter "$CONTAINER_NAME" --root -- sh -c "
    # Import the GPG Key
    rpm --import https://releases.warp.dev/linux/keys/warp.asc

    # Add the official Warp repository
    echo -e '[warpdotdev]\nname=Warp\nbaseurl=https://releases.warp.dev/linux/rpm/\nenabled=1\ngpgcheck=1\ngpgkey=https://releases.warp.dev/linux/keys/warp.asc' > /etc/yum.repos.d/warpdotdev.repo

    # Update and Install
    dnf install -y warp-terminal fontconfig libxkbcommon
"

# 3. Export the application to the Host (Bazzite)
echo "[+] Exporting Warp to Bazzite host..."
distrobox enter "$CONTAINER_NAME" -- sh -c "
    distrobox-export --app warp-terminal
"

echo "---------------------------------------"
echo "[SUCCESS] Warp Terminal has been installed!"
echo "You can now find 'Warp' in your Bazzite Application Menu or Distroshelf."
echo "If it doesn't appear immediately, run 'update-desktop-database ~/.local/share/applications' or log out and back in."

