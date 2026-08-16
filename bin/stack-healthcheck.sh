#!/usr/bin/env bash
# Post-boot self-heal for two known reboot races (see docs/post-reboot-stale-mounts.md):
#   1. gluetun needs a force-recreate on every start (mirrors bin/deploy.sh).
#   2. Traefik can report healthy while Docker silently drops its host port
#      publish; only a force-recreate of traefik itself fixes it.
# Also guards against stale bind-mount views of /mnt/wd/media after reboot.
set -euo pipefail

COMPOSE_DIR="/srv/stoganet/compose"
INTERVENED=0
GAVE_UP=0

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1"
}

cd "$COMPOSE_DIR"

log "Force-recreating gluetun"
docker compose up -d --force-recreate gluetun

log "Bringing up remaining stack"
docker compose up -d --remove-orphans

traefik_ports_published() {
    [ -n "$(docker port traefik 2>/dev/null)" ]
}

log "Checking Traefik host port publish"
TRAEFIK_OK=0
for attempt in 1 2 3; do
    sleep 3
    if traefik_ports_published; then
        TRAEFIK_OK=1
        break
    fi
    log "Traefik ports not published (attempt $attempt/3), force-recreating"
    docker compose up -d --force-recreate traefik
    INTERVENED=1
done

if [ "$TRAEFIK_OK" -eq 0 ]; then
    log "Traefik still has no published ports after 3 attempts, giving up"
    GAVE_UP=1
fi

log "Checking /mnt/wd/media for stale bind mount"
MEDIA_COUNT=$(find /mnt/wd/media -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
if [ "$MEDIA_COUNT" -eq 0 ]; then
    log "/mnt/wd/media looks empty, restarting media containers"
    docker restart jellyfin radarr sonarr bazarr
    INTERVENED=1
fi

log "stack-healthcheck complete (intervened=$INTERVENED gave_up=$GAVE_UP)"

if [ "$GAVE_UP" -eq 1 ]; then
    exit 1
fi
