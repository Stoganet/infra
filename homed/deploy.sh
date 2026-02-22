#!/bin/bash
set -euo pipefail

REPO="koinsaari/homeserver"
BINARY_URL="https://github.com/$REPO/releases/latest/download/homed"
INSTALL_DIR="/opt/homed"
SERVICE_NAME="homed.service"

sudo mkdir -p "$INSTALL_DIR"

echo "Downloading latest homed binary..."
curl -fL -o /tmp/homed "$BINARY_URL"

echo "Checking if service is loaded..."
if systemctl list-unit-files "$SERVICE_NAME" >/dev/null 2>&1; then
    echo "Stopping existing homed service..."
    sudo systemctl stop homed
else
    echo "Service not found, skipping stopping."
fi

echo "Installing binary..."
sudo install -m 755 /tmp/homed "$INSTALL_DIR/homed"
rm /tmp/homed

echo "Reloading systemd and starting service..."
sudo systemctl daemon-reload
sudo systemctl enable homed
sudo systemctl start homed

echo "Done. Status:"
sudo systemctl status homed --no-pager
