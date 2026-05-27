#!/usr/bin/env bash
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 <previous-sha>" >&2
  exit 2
fi
PREVIOUS_SHA="$1"

cd /srv/stoganet
git checkout --quiet "$PREVIOUS_SHA"

cd /srv/stoganet/compose
docker compose up -d
