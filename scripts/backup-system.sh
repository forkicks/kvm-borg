#!/bin/bash

# =============================================================================
# SYSTEM BACKUP SCRIPT
# =============================================================================
#
# Performs a full system backup to a local (and optionally remote) Borg repository.
#
# Features:
#   - Stops configured services before backup for consistency
#   - Runs optional pre-backup commands (e.g., database dumps)
#   - Backs up to local Borg repository
#   - Optionally backs up to remote Borg repository
#   - Prunes old backups according to retention policy
#   - Tracks remote backup success for staleness warnings
#
# Usage:
#   ./backup-system.sh [OPTIONS]
#
# Options:
#   --with-vms      Also run VM backups after system backup
#   --dry-run       Show what would be done without making changes
#   --help          Show this help message
#
# Configuration:
#   See config/backup.conf.example for all configuration options.
#
# =============================================================================

set -e

# Script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
source "$SCRIPT_DIR/lib/common.sh"

# -----------------------------------------------------------------------------
# Parse command line arguments
# -----------------------------------------------------------------------------

WITH_VMS=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --with-vms)
            WITH_VMS=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help)
            head -40 "$0" | tail -35
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--with-vms] [--dry-run] [--help]"
            exit 1
            ;;
    esac
done

# -----------------------------------------------------------------------------
# Load configuration
# -----------------------------------------------------------------------------

load_config "$SCRIPT_DIR" || exit 1

# Set defaults for optional config values
BORG_REPO_SYSTEM="${BORG_REPO_SYSTEM:-/backup/system}"
BORG_COMPRESSION_SYSTEM="${BORG_COMPRESSION_SYSTEM:-lz4}"
BORG_PRUNE_KEEP="${BORG_PRUNE_KEEP:---keep-daily 7 --keep-weekly 4 --keep-monthly 6}"
LOCK_FILE_SYSTEM="${LOCK_FILE_SYSTEM:-/var/run/backup-system.lock}"
REMOTE_STATE_DIR="${REMOTE_STATE_DIR:-/var/lib/backup-state}"
REMOTE_STALE_DAYS="${REMOTE_STALE_DAYS:-14}"

# Find borg binary
BORG="${BORG_BINARY:-$(find_borg)}"

# Export Borg settings
[ -n "${BORG_PASSPHRASE:-}" ] && export BORG_PASSPHRASE
[ -n "${BORG_RSH:-}" ] && export BORG_RSH

# Set up source and archive names
SOURCE_NAME="$(get_hostname)"
ARCHIVE_NAME="${SOURCE_NAME}-$(get_timestamp)"
REMOTE_STATE_FILE="${REMOTE_STATE_DIR}/${SOURCE_NAME}-remote-backup-last-success"

# Build exclude list
EXCLUDES=()
for pattern in "${SYSTEM_EXCLUDES[@]:-}"; do
    [ -n "$pattern" ] && EXCLUDES+=(--exclude "$pattern")
done
for pattern in "${CUSTOM_EXCLUDES[@]:-}"; do
    [ -n "$pattern" ] && EXCLUDES+=(--exclude "$pattern")
done

# Track container states for restore
declare -A container_status

# -----------------------------------------------------------------------------
# Service management functions
# -----------------------------------------------------------------------------

# Get and store the status of all configured services
check_container_states() {
    log "Checking container states..."
    for container in "${CONTAINERS[@]:-}"; do
        container_status[$container]=$(systemctl is-active "$container" 2>/dev/null || echo "inactive")
    done
    for container in "${CONTAINERS_DELAYED_START[@]:-}"; do
        container_status[$container]=$(systemctl is-active "$container" 2>/dev/null || echo "inactive")
    done
}

# Restore services to their original state
restore_services() {
    log "Restoring container services to original state..."

    # Get list of delayed-start containers for filtering
    local delayed_containers=()
    for c in "${CONTAINERS_DELAYED_START[@]:-}"; do
        delayed_containers+=("$c")
    done

    # Start all containers except delayed-start ones first
    for container in "${CONTAINERS[@]:-}"; do
        if [ "${container_status[$container]:-}" = "active" ]; then
            # Check if this is a delayed-start container
            if ! in_array "$container" "${delayed_containers[@]:-}"; then
                if [ "$DRY_RUN" = true ]; then
                    log "[DRY-RUN] Would start $container service"
                else
                    log "Starting $container service..."
                    systemctl start "$container" || warn "Failed to start $container"
                fi
            fi
        fi
    done

    # Wait and start delayed-start containers
    local has_delayed=false
    for container in "${CONTAINERS_DELAYED_START[@]:-}"; do
        if [ "${container_status[$container]:-}" = "active" ]; then
            has_delayed=true
            break
        fi
    done

    if [ "$has_delayed" = true ]; then
        if [ "$DRY_RUN" = true ]; then
            log "[DRY-RUN] Would wait 30 seconds for dependencies to stabilize"
        else
            log "Waiting 30 seconds for dependencies to stabilize..."
            sleep 30
        fi

        for container in "${CONTAINERS_DELAYED_START[@]:-}"; do
            if [ "${container_status[$container]:-}" = "active" ]; then
                if [ "$DRY_RUN" = true ]; then
                    log "[DRY-RUN] Would start $container service (delayed)"
                else
                    log "Starting $container service..."
                    systemctl start "$container" || warn "Failed to start $container"
                fi
            fi
        done
    fi

    log "Service restoration completed"
}

# Stop all configured services
stop_services() {
    log "Stopping containers..."
    for container in "${CONTAINERS[@]:-}"; do
        if [ "${container_status[$container]:-}" = "active" ]; then
            if [ "$DRY_RUN" = true ]; then
                log "[DRY-RUN] Would stop $container service"
            else
                log "Stopping $container service..."
                systemctl stop "$container" || warn "Failed to stop $container"
            fi
        fi
    done
    for container in "${CONTAINERS_DELAYED_START[@]:-}"; do
        if [ "${container_status[$container]:-}" = "active" ]; then
            if [ "$DRY_RUN" = true ]; then
                log "[DRY-RUN] Would stop $container service"
            else
                log "Stopping $container service..."
                systemctl stop "$container" || warn "Failed to stop $container"
            fi
        fi
    done
}

# -----------------------------------------------------------------------------
# Cleanup function
# -----------------------------------------------------------------------------

cleanup() {
    restore_services
    release_lock "$LOCK_FILE_SYSTEM"
}

# -----------------------------------------------------------------------------
# Main backup process
# -----------------------------------------------------------------------------

log "System backup starting for source: $SOURCE_NAME"

if [ "$DRY_RUN" = true ]; then
    log "Running in DRY-RUN mode - no changes will be made"
fi

# Acquire lock to prevent concurrent backups
if ! acquire_lock "$LOCK_FILE_SYSTEM"; then
    error "Could not acquire lock - another backup may be running"
fi

# Set up cleanup trap
trap cleanup EXIT

# Check if remote backup is stale
if [ -n "${REMOTE_BORG_REPO_SYSTEM:-}" ]; then
    check_remote_backup_stale "$REMOTE_STATE_FILE" "$REMOTE_STALE_DAYS" "$SOURCE_NAME" || true
fi

# Validate Borg repository
log "Validating Borg repository: $BORG_REPO_SYSTEM"
if [ "$DRY_RUN" = true ]; then
    log "[DRY-RUN] Would validate repository: $BORG_REPO_SYSTEM"
else
    validate_borg_repo "$BORG_REPO_SYSTEM" "$BORG"
fi

# Get the status of each container first (before stopping any)
check_container_states

# Run pre-backup command if configured
if [ -n "${PRE_BACKUP_SERVICE:-}" ] && [ -n "${PRE_BACKUP_COMMAND:-}" ]; then
    # Stop the service that needs the pre-backup service to be running
    # (e.g., stop Gitea before backing up its database, but keep MariaDB running)
    for container in "${CONTAINERS[@]:-}"; do
        if [ "$container" = "${PRE_BACKUP_SERVICE}" ]; then
            continue  # Keep this one running for now
        fi
        # Find the first non-pre-backup-service container and stop it
        # This is typically the application that uses the database
        break
    done

    # Run pre-backup command
    if [ "$DRY_RUN" = true ]; then
        log "[DRY-RUN] Would run pre-backup command: $PRE_BACKUP_COMMAND"
    else
        log "Running pre-backup command..."
        if ! $PRE_BACKUP_COMMAND; then
            warn "Pre-backup command failed"
        fi
    fi
fi

# Stop remaining containers
stop_services

# Run the backup
log "Starting Borg backup of filesystem..."
if [ "$DRY_RUN" = true ]; then
    log "[DRY-RUN] Would run: $BORG create -C $BORG_COMPRESSION_SYSTEM --stats --progress \"$BORG_REPO_SYSTEM::$ARCHIVE_NAME\" / ${EXCLUDES[*]}"
else
    # Borg exit codes: 0=success, 1=warning (e.g. file changed during backup), 2=error
    set +e
    $BORG create -C "$BORG_COMPRESSION_SYSTEM" --stats --progress "$BORG_REPO_SYSTEM::$ARCHIVE_NAME" / "${EXCLUDES[@]}"
    borg_exit=$?
    set -e

    if [ $borg_exit -eq 1 ]; then
        log "Backup completed with warnings (exit code 1)"
    elif [ $borg_exit -ne 0 ]; then
        error "Backup failed with exit code $borg_exit"
    else
        log "Backup completed successfully!"
    fi
fi

# Prune old backups (only for this source)
log "Pruning old backups for $SOURCE_NAME..."
if [ "$DRY_RUN" = true ]; then
    log "[DRY-RUN] Would prune with: $BORG prune --list --glob-archives \"${SOURCE_NAME}-*\" $BORG_PRUNE_KEEP \"$BORG_REPO_SYSTEM\""
else
    # shellcheck disable=SC2086
    if ! $BORG prune --list --glob-archives "${SOURCE_NAME}-*" $BORG_PRUNE_KEEP "$BORG_REPO_SYSTEM"; then
        warn "Prune operation failed"
    fi
fi

# Compact to reclaim unused space in chunks
log "Compacting repository..."
if [ "$DRY_RUN" = true ]; then
    log "[DRY-RUN] Would compact repository"
else
    if ! $BORG compact "$BORG_REPO_SYSTEM"; then
        warn "Compact operation failed"
    fi
fi

log "Pruning and compacting completed!"
log "Local system backup finished successfully"

# Remote backup (if configured and server is available)
if [ -n "${REMOTE_BORG_REPO_SYSTEM:-}" ] && [ -n "${REMOTE_HOST:-}" ]; then
    if is_remote_available "$REMOTE_HOST"; then
        log "Remote backup server is available, starting remote backup..."

        if [ "$DRY_RUN" = true ]; then
            log "[DRY-RUN] Would create remote backup to $REMOTE_BORG_REPO_SYSTEM"
            log "[DRY-RUN] Would prune and compact remote repository"
        else
            set +e
            $BORG create -C "$BORG_COMPRESSION_SYSTEM" --stats --progress "$REMOTE_BORG_REPO_SYSTEM::$ARCHIVE_NAME" / "${EXCLUDES[@]}"
            borg_exit=$?
            set -e

            if [ $borg_exit -eq 1 ]; then
                log "Remote backup completed with warnings (exit code 1)"
            elif [ $borg_exit -ne 0 ]; then
                warn "Remote backup failed with exit code $borg_exit"
            else
                log "Remote backup completed successfully!"
            fi

            # Only proceed with prune/compact if backup succeeded (exit 0 or 1)
            if [ $borg_exit -le 1 ]; then
                # Prune old remote backups (only for this source)
                log "Pruning old remote backups for $SOURCE_NAME..."
                # shellcheck disable=SC2086
                if ! $BORG prune --list --glob-archives "${SOURCE_NAME}-*" $BORG_PRUNE_KEEP "$REMOTE_BORG_REPO_SYSTEM"; then
                    warn "Remote prune operation failed"
                fi

                # Compact remote repository
                log "Compacting remote repository..."
                if ! $BORG compact "$REMOTE_BORG_REPO_SYSTEM"; then
                    warn "Remote compact operation failed"
                fi

                log "Remote backup operations completed!"
                record_remote_success "$REMOTE_STATE_FILE"
            fi
        fi
    else
        log "Remote backup server not available, skipping remote backup"
    fi
fi

log "System backup process finished successfully"

# Run VM backup if --with-vms flag was provided
if [ "$WITH_VMS" = true ]; then
    log "Starting VM backups (--with-vms option enabled)..."
    VM_SCRIPT="$SCRIPT_DIR/backup-vms.sh"
    if [ -x "$VM_SCRIPT" ]; then
        set +e
        if [ "$DRY_RUN" = true ]; then
            "$VM_SCRIPT" --dry-run
        else
            "$VM_SCRIPT"
        fi
        vm_exit=$?
        set -e

        if [ $vm_exit -eq 0 ]; then
            log "VM backup completed successfully"
        else
            warn "VM backup failed with exit code $vm_exit"
        fi
    else
        warn "VM backup script not found: $VM_SCRIPT"
    fi
    log "All backup operations completed!"
else
    log "Skipping VM backup (use --with-vms to include VM backups)"
fi
