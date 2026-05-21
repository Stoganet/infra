#!/bin/bash
set -euo pipefail

CONFIG_FILE="${BACKUP_CONFIG:-/etc/backup/backup.env}"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1"
}

send_alert() {
    local priority="$1"
    local message="$2"

    if [ -n "${NTFY_URL:-}" ] && [ -n "${NTFY_TOPIC:-}" ]; then
        local auth_args=()
        if [ -n "${NTFY_TOKEN:-}" ]; then
            auth_args=(-H "Authorization: Bearer $NTFY_TOKEN")
        fi
        curl -s \
            -H "Priority: $priority" \
            "${auth_args[@]}" \
            -d "$message" \
            "${NTFY_URL}/${NTFY_TOPIC}" > /dev/null 2>&1 || true
    fi
}

check_disk_space() {
    local mount="$1"
    local min_gb="${2:-10}"

    if ! mountpoint -q "$mount" 2>/dev/null; then
        log "Error: $mount is not mounted"
        return 1
    fi

    local available_kb
    available_kb=$(df -k "$mount" | awk 'NR==2 {print $4}')
    available_kb="${available_kb:-0}"
    local available_gb=$((available_kb / 1024 / 1024))

    if [ "$available_gb" -lt "$min_gb" ]; then
        log "Warning: Only ${available_gb}GB available on backup drive (minimum: ${min_gb}GB)"
        send_alert "high" "Backup warning: only ${available_gb}GB free on backup drive"
        return 1
    fi

    log "Disk space: ${available_gb}GB available"
    return 0
}

dump_databases() {
    local dump_dir="$1"
    mkdir -p "$dump_dir"

    log "Dumping databases..."

    if docker ps --format '{{.Names}}' | grep -q '^postgres$'; then
        log "  Dumping Nextcloud PostgreSQL..."
        if docker exec postgres pg_dumpall -U postgres > "$dump_dir/postgres_nextcloud.sql" 2>/dev/null; then
            log "  Nextcloud PostgreSQL dump: OK"
        else
            log "  Warning: Nextcloud PostgreSQL dump failed"
        fi
    fi

    if docker ps --format '{{.Names}}' | grep -q '^immich-postgres$'; then
        log "  Dumping Immich PostgreSQL..."
        if docker exec immich-postgres pg_dumpall -U postgres > "$dump_dir/postgres_immich.sql" 2>/dev/null; then
            log "  Immich PostgreSQL dump: OK"
        else
            log "  Warning: Immich PostgreSQL dump failed"
        fi
    fi

    log "Database dumps completed"
}

cleanup() {
    if mountpoint -q "$BACKUP_MOUNT" 2>/dev/null; then
        log "Unmounting $BACKUP_MOUNT"
        umount "$BACKUP_MOUNT" || true
    fi
    if [ -e /dev/mapper/backup-vault ]; then
        log "Closing LUKS"
        cryptsetup close backup-vault || true
    fi
}

trap cleanup EXIT INT TERM

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Config file not found: $CONFIG_FILE"
    echo "Copy backup.env.example to $CONFIG_FILE and configure it."
    exit 1
fi

source "$CONFIG_FILE"

: "${BACKUP_DRIVE_UUID:?BACKUP_DRIVE_UUID not set in $CONFIG_FILE}"
: "${BACKUP_MOUNT:=/mnt/samsung}"
: "${BACKUP_KEYFILE:=/etc/backup/backup.key}"
: "${ALERT_ON_MISSING:=false}"
: "${MIN_DISK_SPACE_GB:=10}"
: "${VERIFY_BACKUP:=true}"
: "${DOCKER_VOLUME_PATH:=/var/lib/docker/volumes}"
: "${COMPOSE_PROJECT:=services}"
: "${DB_DUMP_DIR:=/var/lib/backups/db_dumps}"

DRIVE_PATH="/dev/disk/by-uuid/$BACKUP_DRIVE_UUID"

for cmd in rclone cryptsetup; do
    if ! command -v "$cmd" &>/dev/null; then
        log "$cmd not found, installing..."
        apt-get update -qq && apt-get install -y -qq "$cmd"
        if ! command -v "$cmd" &>/dev/null; then
            log "Error: Failed to install $cmd"
            exit 1
        fi
    fi
done

if [ ! -e "$DRIVE_PATH" ]; then
    log "Drive not connected (UUID: $BACKUP_DRIVE_UUID)"
    if [ "$ALERT_ON_MISSING" = "true" ]; then
        send_alert "low" "Backup skipped: drive not connected"
    fi
    exit 0
fi

if [ ! -f "$BACKUP_KEYFILE" ]; then
    log "Error: Keyfile not found: $BACKUP_KEYFILE"
    send_alert "urgent" "Backup FAILED: keyfile not found"
    exit 1
fi

START_TIME=$(date +%s)
log "Starting backup"

log "Opening LUKS partition"
if [ -e /dev/mapper/backup-vault ]; then
    log "LUKS already open (previous run?), continuing"
else
    if ! cryptsetup open "$DRIVE_PATH" backup-vault --key-file "$BACKUP_KEYFILE"; then
        log "Error: Failed to unlock drive"
        send_alert "urgent" "Backup FAILED: could not unlock drive"
        exit 1
    fi
fi

log "Mounting filesystem"
mkdir -p "$BACKUP_MOUNT"
if mountpoint -q "$BACKUP_MOUNT" 2>/dev/null; then
    log "Already mounted (previous run?), continuing"
else
    if ! mount /dev/mapper/backup-vault "$BACKUP_MOUNT"; then
        log "Error: Failed to mount drive"
        send_alert "urgent" "Backup FAILED: could not mount drive"
        exit 1
    fi
fi

if ! check_disk_space "$BACKUP_MOUNT" "$MIN_DISK_SPACE_GB"; then
    log "Continuing backup despite low disk space"
fi

dump_databases "$DB_DUMP_DIR"

TOTAL_FILES=0
FAILED=0
VERIFIED=0

CRITICAL_SOURCES="
$DB_DUMP_DIR
$DOCKER_VOLUME_PATH/${COMPOSE_PROJECT}_vaultwarden_data/_data
$DOCKER_VOLUME_PATH/${COMPOSE_PROJECT}_traefik_certs/_data
"

USER_DATA_SOURCES="${BACKUP_USER_DATA:-}"

CONFIG_SOURCES="
$DOCKER_VOLUME_PATH/${COMPOSE_PROJECT}_jellyfin_config/_data
$DOCKER_VOLUME_PATH/${COMPOSE_PROJECT}_sonarr_config/_data
$DOCKER_VOLUME_PATH/${COMPOSE_PROJECT}_radarr_config/_data
$DOCKER_VOLUME_PATH/${COMPOSE_PROJECT}_prowlarr_config/_data
$DOCKER_VOLUME_PATH/${COMPOSE_PROJECT}_bazarr_config/_data
$DOCKER_VOLUME_PATH/${COMPOSE_PROJECT}_qbittorrent_config/_data
$DOCKER_VOLUME_PATH/${COMPOSE_PROJECT}_syncthing_config/_data
"

ENV_FILES="${BACKUP_ENV_FILES:-}"

backup_sources() {
    local category="$1"
    local sources="$2"

    log "=== Backing up: $category ==="

    for SOURCE in $sources; do
        SOURCE=$(echo "$SOURCE" | xargs)
        [ -z "$SOURCE" ] && continue

        if [ ! -d "$SOURCE" ]; then
            log "  Skipping (not found): $SOURCE"
            continue
        fi

        DIRNAME=$(basename "$SOURCE")
        DEST="$BACKUP_MOUNT/$DIRNAME"

        log "  Copying $SOURCE -> $DEST"

        if OUTPUT=$(rclone copy "$SOURCE" "$DEST" --checksum --stats-one-line 2>&1); then
            FILES=$(echo "$OUTPUT" | grep -oP 'Transferred:\s+\K\d+(?=\s*/|\s+/)' || echo "0")
            FILES=${FILES:-0}
            TOTAL_FILES=$((TOTAL_FILES + FILES))

            if [ "$VERIFY_BACKUP" = "true" ] && [ "$FILES" -gt 0 ]; then
                if rclone check "$SOURCE" "$DEST" --checksum 2>/dev/null; then
                    VERIFIED=$((VERIFIED + 1))
                else
                    log "  Warning: Verification failed for $DIRNAME"
                fi
            fi
        else
            log "  Error: rclone failed for $SOURCE"
            FAILED=1
        fi
    done
}

backup_env_files() {
    local files="$1"

    [ -z "$files" ] && return

    log "=== Backing up env files ==="
    mkdir -p "$BACKUP_MOUNT/secrets"

    for FILE in $files; do
        FILE=$(echo "$FILE" | xargs)
        [ -z "$FILE" ] && continue

        if [ ! -f "$FILE" ]; then
            log "  Skipping (not found): $FILE"
            continue
        fi

        NAME=$(basename "$FILE")
        log "  Copying $NAME"
        if cp "$FILE" "$BACKUP_MOUNT/secrets/$NAME" 2>/dev/null; then
            TOTAL_FILES=$((TOTAL_FILES + 1))
        else
            log "  Error: Failed to copy $NAME"
            FAILED=1
        fi
    done
}

backup_sources "critical" "$CRITICAL_SOURCES"
backup_sources "user_data" "$USER_DATA_SOURCES"
backup_sources "configs" "$CONFIG_SOURCES"
backup_env_files "$ENV_FILES"

# Cleanup old database dumps
find "$DB_DUMP_DIR" -name "*.sql" -mtime +7 -delete 2>/dev/null || true

DURATION=$(( $(date +%s) - START_TIME ))
MINUTES=$((DURATION / 60))
SECONDS=$((DURATION % 60))

if [ "$FAILED" -eq 1 ]; then
    log "Backup completed with errors in ${MINUTES}m ${SECONDS}s"
    send_alert "high" "Backup completed with errors: ${TOTAL_FILES} files in ${MINUTES}m"
    exit 1
else
    log "Backup completed: ${TOTAL_FILES} files, ${VERIFIED} verified in ${MINUTES}m ${SECONDS}s"
    send_alert "default" "Backup OK: ${TOTAL_FILES} files in ${MINUTES}m"
fi
