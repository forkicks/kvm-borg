#!/bin/bash

# =============================================================================
# DATABASE BACKUP SCRIPT
# =============================================================================
#
# Generic database backup script supporting MySQL/MariaDB and PostgreSQL.
#
# Features:
#   - Supports MySQL, MariaDB, and PostgreSQL
#   - Uses password files for security (no plaintext passwords in config)
#   - Compresses backups with gzip
#   - Rotates old backups (keeps configurable number)
#   - Optionally syncs to remote server
#
# Usage:
#   ./backup-database.sh [OPTIONS]
#
# Options:
#   --dry-run       Show what would be done without making changes
#   --help          Show this help message
#
# Configuration:
#   See config/backup.conf.example for all configuration options.
#   Key settings: DB_TYPE, DB_HOST, DB_USER, DB_NAME, DB_PASSWORD_FILE
#
# =============================================================================

set -e

# Script location (resolve symlinks to find actual script directory)
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# Source common functions
source "$SCRIPT_DIR/lib/common.sh"

# -----------------------------------------------------------------------------
# Parse command line arguments
# -----------------------------------------------------------------------------

DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help)
            head -30 "$0" | tail -25
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--dry-run] [--help]"
            exit 1
            ;;
    esac
done

# -----------------------------------------------------------------------------
# Load configuration
# -----------------------------------------------------------------------------

load_config "$SCRIPT_DIR" || exit 1

# Validate required settings
if [ -z "${DB_TYPE:-}" ]; then
    error "DB_TYPE is not configured. Set it in backup.conf (mysql, mariadb, or postgresql)"
fi

if [ -z "${DB_NAME:-}" ]; then
    error "DB_NAME is not configured"
fi

if [ -z "${DB_USER:-}" ]; then
    error "DB_USER is not configured"
fi

# Set defaults
DB_HOST="${DB_HOST:-localhost}"
DB_BACKUP_DIR="${DB_BACKUP_DIR:-/backup/database}"
DB_BACKUP_PREFIX="${DB_BACKUP_PREFIX:-db-backup}"
DB_BACKUP_KEEP="${DB_BACKUP_KEEP:-3}"
LOG_FILE_DATABASE="${LOG_FILE_DATABASE:-/var/log/backup-database.log}"

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------

# Get database password from file
get_db_password() {
    if [ -n "${DB_PASSWORD_FILE:-}" ] && [ -f "$DB_PASSWORD_FILE" ]; then
        cat "$DB_PASSWORD_FILE"
    else
        echo ""
    fi
}

# Backup MySQL/MariaDB database
backup_mysql() {
    local timestamp="$1"
    local backup_path="${DB_BACKUP_DIR}/${DB_BACKUP_PREFIX}-${timestamp}.sql"
    local password
    password=$(get_db_password)

    log "Dumping MySQL/MariaDB database: $DB_NAME"

    if [ "$DRY_RUN" = true ]; then
        log "[DRY-RUN] Would run: mysqldump -u $DB_USER -h $DB_HOST $DB_NAME > $backup_path"
        echo "$backup_path"
        return 0
    fi

    # Set port if specified
    local port_arg=""
    if [ -n "${DB_PORT:-}" ]; then
        port_arg="-P $DB_PORT"
    fi

    # Use MYSQL_PWD environment variable for security
    if [ -n "$password" ]; then
        export MYSQL_PWD="$password"
    fi

    # shellcheck disable=SC2086
    mysqldump -u "$DB_USER" -h "$DB_HOST" $port_arg "$DB_NAME" > "$backup_path"

    # Clear password from environment
    unset MYSQL_PWD

    echo "$backup_path"
}

# Backup PostgreSQL database
backup_postgresql() {
    local timestamp="$1"
    local backup_path="${DB_BACKUP_DIR}/${DB_BACKUP_PREFIX}-${timestamp}.sql"
    local password
    password=$(get_db_password)

    log "Dumping PostgreSQL database: $DB_NAME"

    if [ "$DRY_RUN" = true ]; then
        log "[DRY-RUN] Would run: pg_dump -U $DB_USER -h $DB_HOST $DB_NAME > $backup_path"
        echo "$backup_path"
        return 0
    fi

    # Set port if specified
    local port_arg=""
    if [ -n "${DB_PORT:-}" ]; then
        port_arg="-p $DB_PORT"
    fi

    # Use PGPASSWORD environment variable for security
    if [ -n "$password" ]; then
        export PGPASSWORD="$password"
    fi

    # shellcheck disable=SC2086
    pg_dump -U "$DB_USER" -h "$DB_HOST" $port_arg "$DB_NAME" > "$backup_path"

    # Clear password from environment
    unset PGPASSWORD

    echo "$backup_path"
}

# Rotate old backups - keep only the last N versions
rotate_backups() {
    local dir="$1"
    local prefix="$2"
    local keep="$3"

    log "Rotating old backups (keeping $keep)..."

    if [ "$DRY_RUN" = true ]; then
        local old_files
        old_files=$(ls -t "${dir}/${prefix}"-*.sql.gz 2>/dev/null | tail -n +$((keep + 1)) || true)
        if [ -n "$old_files" ]; then
            log "[DRY-RUN] Would remove old backups:"
            echo "$old_files" | while read -r f; do
                log "[DRY-RUN]   $f"
            done
        else
            log "[DRY-RUN] No old backups to remove"
        fi
        return 0
    fi

    ls -t "${dir}/${prefix}"-*.sql.gz 2>/dev/null | tail -n +$((keep + 1)) | xargs -r rm -f
}

# Sync backups to remote server
sync_to_remote() {
    local dir="$1"
    local prefix="$2"
    local remote_host="$3"
    local remote_dir="$4"
    local keep="$5"

    if [ -z "$remote_host" ] || [ -z "$remote_dir" ]; then
        return 0
    fi

    if ! is_remote_available "$remote_host"; then
        log "Remote server not available, skipping sync"
        return 0
    fi

    log "Remote server available, syncing database backups..."

    if [ "$DRY_RUN" = true ]; then
        log "[DRY-RUN] Would sync to ${remote_host}:${remote_dir}/"
        log "[DRY-RUN] Would rotate remote backups (keeping $keep)"
        return 0
    fi

    rsync -az "${dir}/${prefix}"-*.sql.gz "${remote_host}:${remote_dir}/"

    # Rotate old backups on remote
    log "Rotating old remote backups..."
    ssh "$remote_host" "ls -t ${remote_dir}/${prefix}-*.sql.gz 2>/dev/null | tail -n +$((keep + 1)) | xargs -r rm -f"

    log "Remote sync completed"
}

# -----------------------------------------------------------------------------
# Main backup process
# -----------------------------------------------------------------------------

log "Database backup starting"
log "Database type: $DB_TYPE"
log "Database name: $DB_NAME"
log "Database host: $DB_HOST"

if [ "$DRY_RUN" = true ]; then
    log "Running in DRY-RUN mode - no changes will be made"
fi

# Create backup directory if it doesn't exist
if [ "$DRY_RUN" = true ]; then
    log "[DRY-RUN] Would create directory: $DB_BACKUP_DIR"
else
    mkdir -p "$DB_BACKUP_DIR"
fi

# Generate timestamp
TIMESTAMP=$(get_compact_timestamp)
BACKUP_PATH="${DB_BACKUP_DIR}/${DB_BACKUP_PREFIX}-${TIMESTAMP}.sql"

# Perform backup based on database type
case "${DB_TYPE,,}" in
    mysql|mariadb)
        backup_mysql "$TIMESTAMP" >/dev/null
        ;;
    postgresql|postgres|pgsql)
        backup_postgresql "$TIMESTAMP" >/dev/null
        ;;
    *)
        error "Unsupported database type: $DB_TYPE (supported: mysql, mariadb, postgresql)"
        ;;
esac

# Compress backup
if [ "$DRY_RUN" = true ]; then
    log "[DRY-RUN] Would compress: $BACKUP_PATH"
    BACKUP_PATH="${BACKUP_PATH}.gz"
else
    if [ -n "$BACKUP_PATH" ] && [ -f "$BACKUP_PATH" ]; then
        log "Compressing database dump..."
        gzip "$BACKUP_PATH"
        BACKUP_PATH="${BACKUP_PATH}.gz"
        log "Compressed backup: $BACKUP_PATH"
    fi
fi

# Rotate old local backups
rotate_backups "$DB_BACKUP_DIR" "$DB_BACKUP_PREFIX" "$DB_BACKUP_KEEP"

# Sync to remote if configured
if [ -n "${DB_REMOTE_HOST:-}" ] && [ -n "${DB_REMOTE_BACKUP_DIR:-}" ]; then
    sync_to_remote "$DB_BACKUP_DIR" "$DB_BACKUP_PREFIX" "$DB_REMOTE_HOST" "$DB_REMOTE_BACKUP_DIR" "$DB_BACKUP_KEEP"
fi

# Log completion
if [ "$DRY_RUN" = true ]; then
    log "[DRY-RUN] Database backup would complete: ${DB_BACKUP_PREFIX}-${TIMESTAMP}.sql.gz"
else
    log "Database backup completed: $BACKUP_PATH"
    echo "Database backup completed on $(date) - $BACKUP_PATH" >> "$LOG_FILE_DATABASE"
fi
