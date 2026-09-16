#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo: sudo ./setup.sh"
    exit 1
fi

REAL_USER=${SUDO_USER:-$USER}

if [ "$REAL_USER" = "root" ]; then
    echo "Error: Run this script as a regular user with sudo, not as root directly."
    exit 1
fi

echo "Home Server Setup"
echo "================================"
echo "This script will configure:"
echo "  - ZRAM (4GB compressed swap)"
echo "  - NetBird VPN client"
echo "  - Docker"
echo "  - UFW firewall"
echo "  - Media library structure (/mnt/wd)"
echo ""
read -rp "Continue with installation? (y/n) " -r
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 0
fi

echo ""
echo "[1/8] Updating system..."
apt-get update
apt-get upgrade -y
apt-get install -y curl ufw fail2ban unattended-upgrades git htop ncdu jq rsync tree smartmontools parted zram-tools rclone cryptsetup

echo ""
echo "[2/8] Intel Quick Sync GPU setup..."
INSTALL_GPU="n"
if [ -d /dev/dri ]; then
    echo "Detected /dev/dri - Intel GPU may be available"
    read -rp "Install Intel Quick Sync drivers for Jellyfin transcoding? (y/n) " -r INSTALL_GPU
fi

if [[ $INSTALL_GPU =~ ^[Yy]$ ]]; then
    echo "Installing Intel Quick Sync drivers (i965 for Broadwell support)..."
    if apt-get install -y intel-gpu-tools vainfo i965-va-driver intel-media-va-driver 2>/dev/null; then
        VIDEO_GID=$(getent group video | cut -d: -f3)
        RENDER_GID=$(getent group render | cut -d: -f3)
        echo "Installed: i965-va-driver (legacy) + intel-media-va-driver (modern)"
        echo "Detected video group: $VIDEO_GID, render group: $RENDER_GID"
    else
        echo "Warning: GPU driver installation failed, continuing without Quick Sync"
        VIDEO_GID=""
        RENDER_GID=""
    fi
else
    VIDEO_GID=""
    RENDER_GID=""
fi

echo ""
echo "[3/8] Configuring ZRAM (4GB compressed swap)..."
cat > /etc/default/zramswap << 'EOF'
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF

cat > /etc/sysctl.d/99-zram.conf << 'EOF'
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF

sysctl -p /etc/sysctl.d/99-zram.conf

systemctl restart zramswap

if [ -f /swapfile ]; then
    echo "Disabling old swap file..."
    swapoff /swapfile 2>/dev/null || true
    sed -i '/\/swapfile/d' /etc/fstab
    rm -f /swapfile
fi

echo ""
echo "[4/8] Configuring SSH security..."
if [ -f /etc/ssh/sshd_config ]; then
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
    sed -i 's/^#\?PermitEmptyPasswords.*/PermitEmptyPasswords no/' /etc/ssh/sshd_config
    systemctl restart ssh
fi
systemctl enable fail2ban
systemctl start fail2ban

echo ""
echo "[5/8] Disabling laptop lid suspend..."
sed -i 's/^#\?HandleLidSwitch=.*/HandleLidSwitch=ignore/' /etc/systemd/logind.conf
sed -i 's/^#\?HandleLidSwitchDocked=.*/HandleLidSwitchDocked=ignore/' /etc/systemd/logind.conf
systemctl restart systemd-logind

echo ""
echo "[6/8] Installing Docker..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sh
fi
usermod -aG docker "$REAL_USER"

echo ""
echo "Configuring Docker to wait for /mnt/wd and NetBird before starting..."
MOUNT_UNIT=$(systemctl list-units --type=mount 2>/dev/null | awk '/wd/ {print $1}' | head -1)
MOUNT_UNIT=${MOUNT_UNIT:-mnt-wd.mount}
mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/wait-for-wd.conf << EOF
[Unit]
After=${MOUNT_UNIT} netbird.service
Requires=${MOUNT_UNIT}

[Service]
ExecStartPre=/bin/bash -c 'for i in \$(seq 1 60); do ip addr show wt0 2>/dev/null | grep -q "inet " && exit 0; sleep 1; done; echo "wt0 has no IPv4 after 60s, proceeding anyway"; exit 0'
EOF
systemctl daemon-reload
echo "Drop-in written: After=${MOUNT_UNIT} netbird.service, waits up to 60s for wt0 IP"

echo ""
echo "Installing stack-healthcheck.service..."
cp "$SCRIPT_DIR/../bin/stack-healthcheck.service" /etc/systemd/system/stack-healthcheck.service
systemctl daemon-reload
systemctl enable stack-healthcheck.service
echo "stack-healthcheck.service installed and enabled"

echo ""
echo "[7/8] Installing NetBird..."
if ! command -v netbird &> /dev/null; then
    curl -fsSL https://pkgs.netbird.io/install.sh | sh
fi

echo ""
if netbird status 2>/dev/null | grep -q "Connected"; then
    echo "NetBird is already connected."
else
    read -rp "Configure NetBird VPN now? (y/n) " -r SETUP_NETBIRD
    if [[ $SETUP_NETBIRD =~ ^[Yy]$ ]]; then
        echo ""
        echo "================================================"
        echo "NetBird Authentication"
        echo "================================================"
        echo "Run this in another terminal:"
        echo ""
        echo "  sudo netbird up"
        echo ""
        echo "If it gets stuck, press Ctrl+C here to skip."
        read -rt 300 -p "Press ENTER when connected (5 min timeout)..." || echo "Timeout - skipping NetBird"

        if netbird status 2>/dev/null | grep -q "Connected"; then
            echo "NetBird connected successfully!"
        else
            echo "NetBird not connected. You can set it up later with: sudo netbird up"
        fi
    else
        echo "Skipping NetBird setup. Run 'sudo netbird up' manually when ready."
    fi
fi

echo ""
echo "[8/8] Configuring UFW firewall (zero-trust)..."
if ! ufw status | grep -qw "active"; then
    read -rp "Enter your LAN subnet (e.g., 192.168.1.0/24): " LAN_SUBNET
    LAN_SUBNET=${LAN_SUBNET:-192.168.1.0/24}

    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing

    ufw allow from "$LAN_SUBNET" to any port 22 proto tcp comment 'SSH from LAN'

    ufw allow in on wt0 comment 'NetBird mesh traffic'

    echo "y" | ufw enable
else
    echo "UFW is already active. Skipping firewall reset."
fi

echo ""
echo "Setting up media directories..."

mkdir -p /mnt/wd/media/{downloads/movies,downloads/tv,quarantine,Movies,TV}
chown -R "$REAL_USER:$REAL_USER" /mnt/wd/media 2>/dev/null || true

echo ""
echo "stogad (file watcher / organizer) is maintained in a separate repo."
echo "Install separately from: https://github.com/Stoganet/stogad"
echo ""
echo "Generating .env file..."

if [ -f "$SCRIPT_DIR/.env" ]; then
    echo "Existing .env found, loading values."
    cp "$SCRIPT_DIR/.env" "$SCRIPT_DIR/.env.bak"
    set -a
    # shellcheck disable=SC1090,SC1091
    source "$SCRIPT_DIR/.env"
    set +a
fi

[ -z "${DOMAIN:-}" ] && read -rp "Base domain (e.g., example.com): " DOMAIN
[ -z "${TZ:-}" ]      && read -rp "Timezone (default: Europe/Helsinki): " TZ
TZ=${TZ:-Europe/Helsinki}

echo ""
echo "VPN for qBittorrent (routes torrent traffic through VPN)"
[ -z "${VPN_PROVIDER:-}" ] && read -rp "VPN provider (default: protonvpn): " VPN_PROVIDER
VPN_PROVIDER=${VPN_PROVIDER:-protonvpn}
[ -z "${VPN_TYPE:-}" ] && read -rp "VPN type (default: wireguard): " VPN_TYPE
VPN_TYPE=${VPN_TYPE:-wireguard}
[ -z "${VPN_PRIVATE_KEY:-}" ] && read -rp "WireGuard private key: " VPN_PRIVATE_KEY
[ -z "${VPN_SERVER_COUNTRIES:-}" ] && read -rp "VPN server country (default: Netherlands): " VPN_SERVER_COUNTRIES
VPN_SERVER_COUNTRIES=${VPN_SERVER_COUNTRIES:-Netherlands}

echo ""
echo "NetBird VPN binding"
echo "Run 'ip addr show wt0 | grep inet' to find your NetBird IP"
[ -z "${NETBIRD_IP:-}" ] && read -rp "NetBird IP (e.g., 100.64.x.x): " NETBIRD_IP

REAL_UID=$(id -u "$REAL_USER")
REAL_GID=$(id -g "$REAL_USER")

cat > "$SCRIPT_DIR/.env" << EOF
DOMAIN=$DOMAIN
TZ=$TZ

PUID=$REAL_UID
PGID=$REAL_GID
VIDEO_GID=$VIDEO_GID
RENDER_GID=$RENDER_GID

VPN_PROVIDER=$VPN_PROVIDER
VPN_TYPE=$VPN_TYPE
VPN_PRIVATE_KEY=$VPN_PRIVATE_KEY
VPN_SERVER_COUNTRIES=$VPN_SERVER_COUNTRIES

NETBIRD_IP=$NETBIRD_IP
EOF

chmod 600 "$SCRIPT_DIR/.env"
chown "$REAL_USER:$REAL_USER" "$SCRIPT_DIR/.env"

echo ""
echo "================================================"
echo "Setup Complete!"
echo "================================================"
echo ""
echo "IMPORTANT: You must log out and log back in"
echo "for Docker group changes to take effect."
echo ""
echo "Next steps:"
echo "  1. Log out and log back in"
echo "  2. Verify NetBird: netbird status"
echo "  3. Start services: docker compose up -d"
echo ""
echo "Public services (via NetBird Cloud reverse proxy, needs configuring there):"
echo "  - https://jellyfin.$DOMAIN"
echo "  - https://seerr.$DOMAIN"
echo "  - https://api.$DOMAIN"
echo ""
echo "Mesh-only services (reachable directly at this peer's NetBird IP,"
echo "no TLS - point a DNS A record at the mesh IP for a friendly name):"
echo "  - http://\$NETBIRD_IP:9000  (portainer)"
echo "  - http://\$NETBIRD_IP:8080  (qbittorrent)"
echo "  - http://\$NETBIRD_IP:9696  (prowlarr)"
echo "  - http://\$NETBIRD_IP:8989  (sonarr)"
echo "  - http://\$NETBIRD_IP:7878  (radarr)"
echo "  - http://\$NETBIRD_IP:6767  (bazarr)"
echo "  - http://\$NETBIRD_IP:3001  (uptime-kuma)"
echo ""
echo "Next: run ./configure-arr.sh to apply arr stack settings."
echo "Credentials saved in: $SCRIPT_DIR/.env"
echo "================================================"
