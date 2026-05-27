#!/usr/bin/env bash
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 <target-sha>" >&2
  exit 2
fi
TARGET_SHA="$1"

cd /srv/stoganet
git fetch --quiet origin
git checkout --quiet "$TARGET_SHA"

cd /srv/stoganet/compose
docker compose pull
docker compose up -d

./configure-arr.sh
