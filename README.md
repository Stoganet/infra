# Stoganet/infra

Infrastructure for the Stoganet home server. Single physical host running a Docker Compose stack of self-hosted services (Jellyfin, the *arr stack, Gluetun-tunneled qBittorrent, Jellyseerr, Portainer, Traefik) plus encrypted backups to a removable SSD.

## Repos in this org

- **[infra](https://github.com/Stoganet/infra)** (this repo) — host config: compose stack, backup scripts, Traefik
- **[stogad](https://github.com/Stoganet/stogad)** — native daemon: file watcher, media scanner, photo organizer, push alerts

## Layout

```
infra/
├── compose/      Docker Compose stack (see compose/README.md)
├── backup/       LUKS-encrypted backup to USB SSD (systemd timer + rclone)
└── docs/         Architecture notes and runbooks
```

## Deploy

```
git clone https://github.com/Stoganet/infra.git /srv/stoganet
cd /srv/stoganet/compose
cp services.env.example .env
$EDITOR .env             # fill in domain, VPN keys, API keys, etc.
sudo ./setup.sh          # one-time host bootstrap (Docker, NetBird, UFW, ZRAM)
docker compose up -d
./configure-arr.sh       # apply Sonarr/Radarr/qBittorrent settings
```

Backup setup:

```
cd /srv/stoganet/backup
sudo ./setup.sh /dev/sdX           # one-time LUKS init for the backup drive
sudo cp backup.env.example /etc/backup/backup.env
$EDITOR /etc/backup/backup.env     # fill in UUID and paths
sudo cp backup.{service,timer} /etc/systemd/system/
sudo cp backup.sh /usr/local/bin/
sudo systemctl daemon-reload
sudo systemctl enable --now backup.timer
```
