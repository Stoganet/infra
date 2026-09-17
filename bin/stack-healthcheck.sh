#!/usr/bin/env bash
# Post-boot self-heal for two known reboot races (see docs/post-reboot-stale-mounts.md):
#   1. gluetun needs a force-recreate on every start (mirrors bin/deploy.sh).
#   2. Any directly mesh-published service can report healthy while Docker
#      silently drops its host port publish; only a force-recreate fixes it.
# Also guards against stale bind-mount views of /mnt/wd/media after reboot.
set -euo pipefail

COMPOSE_DIR="/srv/stoganet/compose"
INTERVENED=0
GAVE_UP=0

# Services with a host port bound to NETBIRD_IP in docker-compose.yml.
PUBLISHED_SERVICES=(portainer jellyfin gluetun prowlarr sonarr radarr bazarr jellyseerr uptime-kuma api-proxy)

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1"
}

cd "$COMPOSE_DIR"

log "Force-recreating gluetun"
docker compose up -d --force-recreate gluetun

log "Bringing up remaining stack"
docker compose up -d --remove-orphans

ports_published() {
    [ -n "$(docker port "$1" 2>/dev/null)" ]
}

RESULT_DIR="$(mktemp -d)"
trap 'rm -rf "$RESULT_DIR"' EXIT

check_one() {
    local svc="$1"
    local ok=0
    for attempt in 1 2 3; do
        sleep 3
        if ports_published "$svc"; then
            ok=1
            break
        fi
        log "$svc ports not published (attempt $attempt/3), force-recreating"
        docker compose up -d --force-recreate "$svc" >>"$RESULT_DIR/$svc.log" 2>&1
        echo 1 > "$RESULT_DIR/$svc.intervened"
    done
    echo "$ok" > "$RESULT_DIR/$svc.ok"
}

log "Checking host port publish for: ${PUBLISHED_SERVICES[*]}"
for svc in "${PUBLISHED_SERVICES[@]}"; do
    check_one "$svc" &
done
wait

for svc in "${PUBLISHED_SERVICES[@]}"; do
    [ -f "$RESULT_DIR/$svc.intervened" ] && INTERVENED=1
    if [ "$(cat "$RESULT_DIR/$svc.ok")" -eq 0 ]; then
        log "$svc still has no published ports after 3 attempts, giving up"
        GAVE_UP=1
    fi
done

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
