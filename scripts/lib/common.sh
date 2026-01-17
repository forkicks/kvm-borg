#!/bin/bash

# =============================================================================
# COMMON LIBRARY - Shared functions for kvm-borg backup scripts
# =============================================================================
#
# Source this file at the beginning of each backup script:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib/common.sh"
#
# =============================================================================

# -----------------------------------------------------------------------------
# Configuration Loading
# -----------------------------------------------------------------------------

# Find and load the configuration file
# Priority: 1. Environment variable BACKUP_CONF
#           2. /etc/kvm-borg/backup.conf
#           3. Script directory config/backup.conf
load_config() {
    local script_dir="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    local config_file=""

    # Check for config file in order of priority
    if [ -n "${BACKUP_CONF:-}" ] && [ -f "$BACKUP_CONF" ]; then
        config_file="$BACKUP_CONF"
    elif [ -f "/etc/kvm-borg/backup.conf" ]; then
        config_file="/etc/kvm-borg/backup.conf"
    elif [ -f "$script_dir/../config/backup.conf" ]; then
        config_file="$script_dir/../config/backup.conf"
    else
        echo "ERROR: No configuration file found!" >&2
        echo "Please create one of:" >&2
        echo "  - /etc/kvm-borg/backup.conf" >&2
        echo "  - $script_dir/../config/backup.conf" >&2
        echo "  - Set BACKUP_CONF environment variable" >&2
        return 1
    fi

    # Source the configuration file
    # shellcheck source=/dev/null
    source "$config_file"
    log "Loaded configuration from: $config_file"

    return 0
}

# -----------------------------------------------------------------------------
# Logging Functions
# -----------------------------------------------------------------------------

# Log a message with timestamp (to stderr so it's not captured by $())
log() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") - $1" >&2
}

# Log a warning message
warn() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") - WARNING: $1" >&2
}

# Log an error message and exit
error() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") - ERROR: $1" >&2
    exit 1
}

# -----------------------------------------------------------------------------
# Lock File Management
# -----------------------------------------------------------------------------

# Acquire an exclusive lock using flock
# Usage: acquire_lock "/var/run/my-script.lock"
acquire_lock() {
    local lock_file="$1"

    # Create lock file directory if it doesn't exist
    mkdir -p "$(dirname "$lock_file")" 2>/dev/null || true

    # Open file descriptor 200 for the lock file
    exec 200>"$lock_file"

    if ! flock -n 200; then
        log "Error: Another instance is already running (lock file: $lock_file)"
        return 1
    fi

    # Write PID to lock file for debugging
    echo $$ >&200
    log "Lock acquired: $lock_file"
    return 0
}

# Release an exclusive lock
# Usage: release_lock "/var/run/my-script.lock"
release_lock() {
    local lock_file="$1"
    flock -u 200 2>/dev/null || true
    rm -f "$lock_file" 2>/dev/null || true
}

# Alternative lock mechanism using PID files
# Usage: create_pid_lock "/var/run/my-script.lock"
create_pid_lock() {
    local lock_file="$1"

    if [ -e "$lock_file" ] && kill -0 "$(cat "$lock_file" 2>/dev/null)" 2>/dev/null; then
        log "Another instance of the script is already running (PID: $(cat "$lock_file"))"
        return 1
    fi

    mkdir -p "$(dirname "$lock_file")" 2>/dev/null || true
    echo $$ > "$lock_file"
    trap 'rm -f "'"$lock_file"'"; exit $?' INT TERM EXIT
    return 0
}

# Remove PID lock file
remove_pid_lock() {
    local lock_file="$1"
    rm -f "$lock_file"
    trap - INT TERM EXIT
}

# -----------------------------------------------------------------------------
# Remote Connectivity
# -----------------------------------------------------------------------------

# Check if a remote host is available via SSH
# Usage: is_remote_available "hostname" [timeout_seconds]
is_remote_available() {
    local host="$1"
    local timeout="${2:-5}"

    if [ -z "$host" ]; then
        return 1
    fi

    ssh -o ConnectTimeout="$timeout" -o BatchMode=yes "$host" "exit 0" 2>/dev/null
}

# Extract hostname from SSH URL
# Usage: get_host_from_ssh_url "ssh://user@host:port/path"
get_host_from_ssh_url() {
    local url="$1"

    # Remove ssh:// prefix
    url="${url#ssh://}"

    # Remove path
    url="${url%%/*}"

    # Remove port
    url="${url%:*}"

    # Remove user
    url="${url#*@}"

    echo "$url"
}

# -----------------------------------------------------------------------------
# Remote Backup State Tracking
# -----------------------------------------------------------------------------

# Record successful remote backup timestamp
# Usage: record_remote_success "/var/lib/backup-state/hostname-remote-last-success"
record_remote_success() {
    local state_file="$1"
    mkdir -p "$(dirname "$state_file")"
    date +%s > "$state_file"
}

# Check if remote backup is stale (hasn't succeeded recently)
# Usage: check_remote_backup_stale "/var/lib/backup-state/hostname-remote-last-success" 14
check_remote_backup_stale() {
    local state_file="$1"
    local stale_days="${2:-14}"
    local source_name="${3:-$(hostname -s)}"

    if [ ! -f "$state_file" ]; then
        warn "No record of successful remote backup for $source_name exists!"
        return 1
    fi

    local last_success
    last_success=$(cat "$state_file")
    local now
    now=$(date +%s)
    local age_days=$(( (now - last_success) / 86400 ))

    if [ "$age_days" -ge "$stale_days" ]; then
        warn "Last successful remote backup for $source_name was $age_days days ago!"
        return 1
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Borg Repository Validation
# -----------------------------------------------------------------------------

# Validate that a path is a valid Borg repository
# Usage: validate_borg_repo "/path/to/repo" [borg_binary]
validate_borg_repo() {
    local repo="$1"
    local borg="${2:-borg}"

    if [ -z "$repo" ]; then
        error "No Borg repository specified"
    fi

    if ! "$borg" info "$repo" &>/dev/null; then
        error "The specified path is not a valid Borg repository: $repo"
    fi

    log "Validated Borg repository: $repo"
    return 0
}

# -----------------------------------------------------------------------------
# Service Management
# -----------------------------------------------------------------------------

# Check if a systemd service is active
# Usage: is_service_active "service-name"
is_service_active() {
    local service="$1"
    [ "$(systemctl is-active "$service" 2>/dev/null)" = "active" ]
}

# Stop a systemd service if it's running
# Usage: stop_service_if_running "service-name"
stop_service_if_running() {
    local service="$1"

    if is_service_active "$service"; then
        log "Stopping $service service..."
        if systemctl stop "$service"; then
            return 0
        else
            warn "Failed to stop $service"
            return 1
        fi
    fi
    return 0
}

# Start a systemd service
# Usage: start_service "service-name"
start_service() {
    local service="$1"

    log "Starting $service service..."
    if systemctl start "$service"; then
        return 0
    else
        warn "Failed to start $service"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Array/List Helpers
# -----------------------------------------------------------------------------

# Check if an element exists in an array
# Usage: in_array "element" "${array[@]}"
in_array() {
    local needle="$1"
    shift
    local element
    for element in "$@"; do
        if [ "$element" = "$needle" ]; then
            return 0
        fi
    done
    return 1
}

# Build Borg exclude arguments from an array
# Usage: excludes=($(build_borg_excludes "${SYSTEM_EXCLUDES[@]}"))
build_borg_excludes() {
    local excludes=()
    for pattern in "$@"; do
        excludes+=(--exclude "$pattern")
    done
    printf '%s\n' "${excludes[@]}"
}

# -----------------------------------------------------------------------------
# Dry Run Support
# -----------------------------------------------------------------------------

# Global dry-run flag (can be set by scripts)
DRY_RUN=${DRY_RUN:-false}

# Execute a command, or print it in dry-run mode
# Usage: run_cmd "description" command arg1 arg2
run_cmd() {
    local desc="$1"
    shift

    if [ "$DRY_RUN" = true ]; then
        log "[DRY-RUN] Would execute: $*"
    else
        log "$desc"
        "$@"
    fi
}

# -----------------------------------------------------------------------------
# Utility Functions
# -----------------------------------------------------------------------------

# Get the current hostname (short form)
get_hostname() {
    echo "${HOSTNAME:-$(hostname -s)}"
}

# Get current timestamp for archive names
get_timestamp() {
    date +%Y-%m-%d-%H%M%S
}

# Get current timestamp in compact format
get_compact_timestamp() {
    date +%Y%m%d_%H%M%S
}

# Find the borg binary (checks common locations)
find_borg() {
    local borg_paths=(
        "/usr/local/bin/borg"
        "/usr/bin/borg"
        "$(command -v borg 2>/dev/null)"
    )

    for path in "${borg_paths[@]}"; do
        if [ -n "$path" ] && [ -x "$path" ]; then
            echo "$path"
            return 0
        fi
    done

    error "borg binary not found. Please install borgbackup."
}

# -----------------------------------------------------------------------------
# Cleanup trap helper
# -----------------------------------------------------------------------------

# Set up a cleanup function to be called on exit
# Usage: setup_cleanup cleanup_function
setup_cleanup() {
    local cleanup_func="$1"
    trap "$cleanup_func" EXIT INT TERM
}
