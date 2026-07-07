#!/bin/bash

# ==============================================================================
# Advanced UpdraftPlus Backup Collector
# Auto-discovers running WordPress Docker containers and copies ALL
# UpdraftPlus backups to the host server, organized by site and date.
# Folder structure: ~/backups/updraft/<site>/<YYYY-MM-DD-HHMM>/
# Skips files that already exist instead of overwriting.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------

DEST_BASE="$HOME/backups/updraft"
LOG_DIR="$HOME/logs"
LOG_FILE="$LOG_DIR/updraft-collector.log"
LOCK_FILE="/tmp/updraft-collector.lock"
RETENTION_DAYS=14
UPDRAFT_DIRS=(
    "/var/www/html/wp-content/updraft"
    "/var/www/html/wp-content/uploads/updraftplus"
    "/var/www/html/wp-content/backup"
)

# ------------------------------------------------------------------------------
# Helper Functions
# ------------------------------------------------------------------------------

log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_FILE"
}

info()  { log "INFO"  "$@"; }
warn()  { log "WARN"  "$@"; }
error() { log "ERROR" "$@"; }

cleanup_lock() {
    rm -f "$LOCK_FILE"
}

# ------------------------------------------------------------------------------
# Prevent concurrent runs
# ------------------------------------------------------------------------------

if [ -f "$LOCK_FILE" ]; then
    PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "unknown")
    if kill -0 "$PID" 2>/dev/null; then
        error "Another instance is already running (PID: $PID). Exiting."
        exit 1
    else
        warn "Stale lock file found. Removing it."
        rm -f "$LOCK_FILE"
    fi
fi

echo $$ > "$LOCK_FILE"
trap cleanup_lock EXIT

# ------------------------------------------------------------------------------
# Create destination and log directories
# ------------------------------------------------------------------------------

mkdir -p "$DEST_BASE"
mkdir -p "$LOG_DIR"

info "=== UpdraftPlus Backup Collector Started ==="
info "Destination: $DEST_BASE"

# ------------------------------------------------------------------------------
# Discover WordPress containers
# ------------------------------------------------------------------------------

info "Discovering running WordPress containers..."

WP_CONTAINERS=$(docker ps --format '{{.ID}}|{{.Image}}|{{.Names}}' | grep -i 'wordpress' || true)

if [ -z "$WP_CONTAINERS" ]; then
    warn "No WordPress containers found by image name. Falling back to all running containers."
    WP_CONTAINERS=$(docker ps --format '{{.ID}}|{{.Image}}|{{.Names}}')
fi

if [ -z "$WP_CONTAINERS" ]; then
    error "No running containers found. Exiting."
    exit 1
fi

TOTAL_CONTAINERS=$(echo "$WP_CONTAINERS" | wc -l)
info "Found $TOTAL_CONTAINERS container(s) to process."

# ------------------------------------------------------------------------------
# Process each container
# ------------------------------------------------------------------------------

SUCCESS_COUNT=0
SKIP_COUNT=0

while IFS='|' read -r CONTAINER_ID CONTAINER_IMAGE CONTAINER_NAME; do

    info "--------------------------------------------------"
    info "Processing container: $CONTAINER_NAME ($CONTAINER_IMAGE) [$CONTAINER_ID]"

    SOURCE_DIR=""
    for DIR in "${UPDRAFT_DIRS[@]}"; do
        if docker exec "$CONTAINER_ID" test -d "$DIR" 2>/dev/null; then
            SOURCE_DIR="$DIR"
            info "Found Updraft directory: $SOURCE_DIR"
            break
        fi
    done

    if [ -z "$SOURCE_DIR" ]; then
        warn "No UpdraftPlus backup directory found in $CONTAINER_NAME. Skipping."
        ((SKIP_COUNT++)) || true
        continue
    fi

    FILES=$(docker exec "$CONTAINER_ID" ls -1 "$SOURCE_DIR" 2>/dev/null | grep -E '^backup_[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}_.+_[a-f0-9]+-' || true)

    if [ -z "$FILES" ]; then
        warn "No UpdraftPlus backup files found in $CONTAINER_NAME. Skipping."
        continue
    fi

    declare -A BACKUP_SETS

    while IFS= read -r FILE; do
        PREFIX=$(echo "$FILE" | sed -E 's/^(backup_[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}_.+_[a-f0-9]+)-.*/\1/')
        if [ -n "$PREFIX" ]; then
            BACKUP_SETS["$PREFIX"]+="$FILE"$'\n'
        fi
    done <<< "$FILES"

    TOTAL_SETS=${#BACKUP_SETS[@]}
    info "Found $TOTAL_SETS backup set(s) in $CONTAINER_NAME"

    for PREFIX in "${!BACKUP_SETS[@]}"; do

        # Parse prefix: backup_YYYY-MM-DD-HHMM_SiteName_HASH
        DATE_TIME=$(echo "$PREFIX" | sed -E 's/backup_([0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4})_.*/\1/')
        BACKUP_DATE=$(echo "$DATE_TIME" | sed -E 's/([0-9]{4}-[0-9]{2}-[0-9]{2})-.*/\1/')
        BACKUP_TIME=$(echo "$DATE_TIME" | sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}-([0-9]{4})/\1/')
        SITE_NAME=$(echo "$PREFIX" | sed -E 's/backup_[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}_(.+)_[a-f0-9]+$/\1/')
        SITE_NAME_SAFE=$(echo "$SITE_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9_-')

        DEST_DIR="$DEST_BASE/$SITE_NAME_SAFE/$BACKUP_DATE-$BACKUP_TIME"
        mkdir -p "$DEST_DIR"

        info "Processing backup set for site '$SITE_NAME' into $DEST_DIR"

        SET_FILES=$(echo "${BACKUP_SETS[$PREFIX]}" | grep -v '^$' || true)
        COPIED=0
        EXISTED=0

        while IFS= read -r FILE; do
            [ -z "$FILE" ] && continue

            DEST_FILE="$DEST_DIR/$FILE"

            if [ -f "$DEST_FILE" ]; then
                warn "File already exists, skipping: $DEST_FILE"
                ((EXISTED++)) || true
                continue
            fi

            info "Copying $FILE ..."
            if docker cp "$CONTAINER_ID:$SOURCE_DIR/$FILE" "$DEST_FILE"; then
                ((COPIED++)) || true
            else
                error "Failed to copy $FILE from $CONTAINER_NAME"
            fi
        done <<< "$SET_FILES"

        info "Copied $COPIED new file(s), skipped $EXISTED existing file(s) for $SITE_NAME"

    done

    ((SUCCESS_COUNT++)) || true

done <<< "$WP_CONTAINERS"

# ------------------------------------------------------------------------------
# Cleanup old backups
# ------------------------------------------------------------------------------

info "Cleaning up backups older than $RETENTION_DAYS days..."
find "$DEST_BASE" -maxdepth 3 -type d -regextype posix-extended -regex '.*/[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}$' -mtime +$RETENTION_DAYS -exec rm -rf {} + 2>/dev/null || true
info "Cleanup completed."

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------

info "=== Backup Collector Finished ==="
info "Containers processed successfully: $SUCCESS_COUNT"
info "Containers skipped/failed: $SKIP_COUNT"

if [ "$SKIP_COUNT" -gt 0 ]; then
    exit 1
fi

exit 0
