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

## Host prep for CI deploys

One-time setup before the `Deploy` GitHub Actions workflow can reach the home box. Run as root or with sudo on the home box.

```bash
# Create deploy user with docker access
sudo useradd -m -s /bin/bash deploy
sudo usermod -aG docker deploy

# Place repo at the expected path, owned by deploy
sudo install -d -o deploy -g deploy /srv/stoganet
sudo -u deploy git clone https://github.com/Stoganet/infra.git /srv/stoganet

# Authorize the deploy public key (paste the one you generated on your laptop)
sudo -u deploy mkdir -p /home/deploy/.ssh
sudo -u deploy chmod 700 /home/deploy/.ssh
echo "ssh-ed25519 AAAA... deploy@gha" | sudo -u deploy tee -a /home/deploy/.ssh/authorized_keys
sudo -u deploy chmod 600 /home/deploy/.ssh/authorized_keys

# Make bin/ scripts executable (already +x in repo, but defensive)
sudo -u deploy chmod +x /srv/stoganet/bin/*.sh
```

On your laptop, generate the deploy keypair (do not reuse personal keys):

```bash
ssh-keygen -t ed25519 -f ~/.ssh/stoganet_infra_deploy -C "deploy@gha-infra" -N ""
```

Capture the home box's SSH host key over the NetBird overlay (from your laptop, already joined to NetBird):

```bash
ssh-keyscan -t ed25519 <home-overlay-ip>
```

Generate a NetBird reusable setup key from the netbird-server dashboard (one-year expiry, ephemeral-peer enabled).

Set the following secrets on the `Stoganet/infra` repo (Settings → Secrets and variables → Actions):

| Secret | Value |
| --- | --- |
| `NB_SETUP_KEY` | The NetBird reusable setup key |
| `DEPLOY_SSH_KEY` | Contents of `~/.ssh/stoganet_infra_deploy` (the private key) |
| `HOME_OVERLAY_IP` | Home box's NetBird IP (`ip -4 -o addr show wt0` on the host) |
| `HOME_SSH_HOST_KEY` | The line from `ssh-keyscan` above (just the key portion, e.g. `ssh-ed25519 AAAA...`) |
| `RENOVATE_TOKEN` | Fine-grained PAT with contents+PRs+issues write on this repo (reusable across Stoganet repos) |

Verify by SSHing from your laptop:

```bash
ssh -i ~/.ssh/stoganet_infra_deploy deploy@<home-overlay-ip> /srv/stoganet/bin/diagnostics.sh
```

Once this returns the diagnostic output, the deploy workflow has everything it needs.
