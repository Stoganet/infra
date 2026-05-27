#!/usr/bin/env bash
# Read-only state dump for deploy.yml failure summaries.
# Intentionally uses `set +e` so a missing container/log does not abort the dump.
set +e

echo "### Home box HEAD"
echo '```'
git -C /srv/stoganet rev-parse HEAD
echo '```'
echo

echo "### docker compose ps"
echo '```'
docker compose -f /srv/stoganet/compose/docker-compose.yml ps
echo '```'
echo

for svc in traefik jellyfin gluetun qbittorrent sonarr radarr; do
  echo "### docker logs --tail 50 $svc"
  echo '```'
  docker logs --tail 50 "$svc" 2>&1
  echo '```'
  echo
done
