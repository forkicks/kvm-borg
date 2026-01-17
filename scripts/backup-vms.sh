#!/bin/bash

# =============================================================================
# KVM VM BACKUP SCRIPT
# =============================================================================
#
# Backs up KVM/libvirt virtual machines to a Borg repository.
#
# Features:
#   - Backs up VM XML configuration
#   - Backs up all disk images (including full backing file chains)
#   - Backs up NVRAM files for UEFI VMs
#   - Handles both file-based and block device disks
#   - Gracefully shuts down running VMs and restarts them after backup
#   - Supports local and remote Borg repositories
#
# Usage:
#   ./backup-vms.sh [OPTIONS] [BORG_REPO] [VM_NAME]
#
# Options:
#   --dry-run       Show what would be done without making changes
#   --help          Show this help message
#
# Arguments:
#   BORG_REPO       Override the default Borg repository path
#   VM_NAME         Only backup this specific VM
#
# Configuration:
#   See config/backup.conf.example for all configuration options.
#
# =============================================================================

# Script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
source "$SCRIPT_DIR/lib/common.sh"

# -----------------------------------------------------------------------------
# Parse command line arguments
# -----------------------------------------------------------------------------

DRY_RUN=false
BORG_REPO_OVERRIDE=""
VM_NAME_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help)
            head -35 "$0" | tail -30
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"
            echo "Usage: $0 [--dry-run] [--help] [BORG_REPO] [VM_NAME]"
            exit 1
            ;;
        *)
            if [ -z "$BORG_REPO_OVERRIDE" ]; then
                BORG_REPO_OVERRIDE="$1"
            else
                VM_NAME_OVERRIDE="$1"
            fi
            shift
            ;;
    esac
done

# -----------------------------------------------------------------------------
# Load configuration
# -----------------------------------------------------------------------------

load_config "$SCRIPT_DIR" || exit 1

# Use override or config values
BORG_REPO="${BORG_REPO_OVERRIDE:-${BORG_REPO_VMS:-/backup/kvm}}"

# Set defaults for optional config values
BORG_COMPRESSION_VMS="${BORG_COMPRESSION_VMS:-zstd,5}"
BORG_PRUNE_KEEP="${BORG_PRUNE_KEEP:---keep-daily 7 --keep-weekly 4 --keep-monthly 6}"
LOCK_FILE_VMS="${LOCK_FILE_VMS:-/var/run/backup-vms.lock}"
BACKUP_TMP_DIR="${BACKUP_TMP_DIR:-/tmp/kvm_backup}"

# Find borg binary
BORG="${BORG_BINARY:-$(find_borg)}"

# Export Borg settings
[ -n "${BORG_PASSPHRASE:-}" ] && export BORG_PASSPHRASE
[ -n "${BORG_RSH:-}" ] && export BORG_RSH

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------

# Validate VM name exists
validate_vm_name() {
    local vm=$1
    if ! virsh dominfo "$vm" &>/dev/null; then
        error "The specified VM does not exist: $vm"
    fi
}

# Get the full backing file chain for a qcow2 image
get_backing_chain() {
    local disk="$1"
    local chain=()
    local current="$disk"

    while [[ -n "$current" ]]; do
        chain+=("$current")
        # Only check backing file if current file exists
        if [[ ! -f "$current" ]]; then
            warn "File in backing chain does not exist: $current"
            break
        fi
        # Get backing file using qemu-img info
        local backing
        backing=$(qemu-img info "$current" 2>/dev/null | grep "^backing file:" | sed 's/^backing file: //')
        if [[ -z "$backing" ]]; then
            break
        fi
        # Handle relative paths - make them absolute relative to current file's directory
        if [[ "$backing" != /* ]]; then
            local dir
            dir=$(dirname "$current")
            backing="$dir/$backing"
        fi
        current="$backing"
    done

    # Return unique files (in case of duplicates)
    printf '%s\n' "${chain[@]}" | sort -u
}

# Discover VM metadata (disks, NVRAM, etc.)
discover_vm() {
    local vm="$1"
    local vm_tmp_dir="$BACKUP_TMP_DIR/$vm"

    log "Discovering metadata for VM: $vm"
    mkdir -p "$vm_tmp_dir"

    local xml_file="$vm_tmp_dir/config.xml"
    local disks=()
    local block_disks=()
    local extra_files=()

    # Correctly parse both file and block disks with spaces
    while IFS= read -r line; do
        # Skip lines that are empty or have "-"
        if [[ -n "$line" && "$line" != "-" ]]; then
            # Extract only the path, ignoring the device name and extra spaces
            path=$(echo "$line" | awk '{$1=""; print substr($0,2)}')
            # Skip empty paths or "-" (empty cdrom/floppy)
            if [[ -z "$path" || "$path" == "-" ]]; then
                continue
            fi
            if [[ "$path" == /dev/* ]]; then
                block_disks+=("$path")
            else
                disks+=("$path")
            fi
        fi
    done < <(virsh domblklist "${vm}" --details | grep file | grep -v cdrom | awk '{print $3, $4, $5, $6, $7, $8, $9}' | xargs -I{} echo {})

    log "Dumping XML configuration for VM: $vm"
    virsh dumpxml "${vm}" > "${xml_file}"

    # Extract NVRAM path for UEFI VMs (critical for boot)
    local nvram_path
    nvram_path=$(grep -oP '<nvram[^>]*>\K[^<]+' "${xml_file}" 2>/dev/null || true)
    if [[ -n "$nvram_path" && -f "$nvram_path" ]]; then
        log "Found NVRAM file: $nvram_path"
        extra_files+=("$nvram_path")
    fi

    # Expand disks to include full backing file chains
    local all_disks=()
    for disk in "${disks[@]}"; do
        while IFS= read -r chain_file; do
            if [[ -n "$chain_file" ]]; then
                all_disks+=("$chain_file")
            fi
        done < <(get_backing_chain "$disk")
    done
    # Remove duplicates and update disks array
    if [ ${#all_disks[@]} -gt 0 ]; then
        mapfile -t disks < <(printf '%s\n' "${all_disks[@]}" | sort -u)
    fi

    log "Disk paths for VM: $vm"
    if [ ${#disks[@]} -eq 0 ]; then
        log "No file-based disks found for VM: $vm"
    else
        for disk in "${disks[@]}"; do
            log "Disk: $disk"
        done
    fi

    log "Block device paths for VM: $vm"
    if [ ${#block_disks[@]} -eq 0 ]; then
        log "No block devices found for VM: $vm"
    else
        for disk in "${block_disks[@]}"; do
            log "Block Device: $disk"
        done
    fi

    log "Extra files for VM: $vm"
    if [ ${#extra_files[@]} -eq 0 ]; then
        log "No extra files (NVRAM, etc.) found for VM: $vm"
    else
        for file in "${extra_files[@]}"; do
            log "Extra file: $file"
        done
    fi

    # Save metadata to files for later use
    printf '%s\n' "${disks[@]}" > "$vm_tmp_dir/disks.txt"
    printf '%s\n' "${block_disks[@]}" > "$vm_tmp_dir/block_disks.txt"
    printf '%s\n' "${extra_files[@]}" > "$vm_tmp_dir/extra_files.txt"
}

# Backup a physical disk
backup_physical_disk() {
    local disk="$1"
    local vm="$2"
    local repo="${3:-$BORG_REPO}"
    local partitions=()
    mapfile -t partitions < <(lsblk -o NAME,TYPE -p -n -l "$disk" | awk '$2 == "part" {print $1}')

    log "Backing up physical disk: $disk"

    if [[ ${#partitions[@]} -gt 0 ]]; then
        log "Handling partitions on physical disk: $disk"
        for partition in "${partitions[@]}"; do
            local fs_type
            fs_type=$(lsblk -f "$partition" -n -o FSTYPE)
            log "Backing up partition: $partition (FS type: $fs_type)"

            local archive_name="${vm}-partition-$(basename "$partition")-$(get_compact_timestamp)"

            if [ "$DRY_RUN" = true ]; then
                log "[DRY-RUN] Would backup partition $partition to $repo::$archive_name"
                continue
            fi

            if [[ "$fs_type" == "ntfs" ]]; then
                log "Backing up NTFS partition: $partition"
                ntfsclone -so - "$partition" | $BORG create --verbose --stats --show-rc "${repo}::${archive_name}" -
            elif [[ "$fs_type" == ext* ]]; then
                log "Backing up ext* partition: $partition"
                zerofree "$partition"
                $BORG create --verbose --stats --show-rc --read-special "${repo}::${archive_name}" "$partition"
            else
                log "Backing up other partition type: $partition"
                $BORG create --verbose --stats --show-rc --read-special "${repo}::${archive_name}" "$partition"
            fi
        done
    else
        log "No partitions found, backing up whole disk: $disk"
        local archive_name="${vm}-disk-$(basename "$disk")-$(get_compact_timestamp)"
        if [ "$DRY_RUN" = true ]; then
            log "[DRY-RUN] Would backup disk $disk to $repo::$archive_name"
        else
            $BORG create --verbose --stats --show-rc --read-special "${repo}::${archive_name}" "$disk"
        fi
    fi
}

# Backup a single VM to a repository (uses cached metadata)
backup_vm_to_repo() {
    local vm="$1"
    local repo="$2"
    local vm_tmp_dir="$BACKUP_TMP_DIR/$vm"

    log "Backing up VM: $vm to $repo"

    local xml_file="$vm_tmp_dir/config.xml"
    local disks=()
    local block_disks=()
    local extra_files=()

    # Load cached metadata
    if [[ -s "$vm_tmp_dir/disks.txt" ]]; then
        mapfile -t disks < "$vm_tmp_dir/disks.txt"
    fi
    if [[ -s "$vm_tmp_dir/block_disks.txt" ]]; then
        mapfile -t block_disks < "$vm_tmp_dir/block_disks.txt"
    fi
    if [[ -s "$vm_tmp_dir/extra_files.txt" ]]; then
        mapfile -t extra_files < "$vm_tmp_dir/extra_files.txt"
    fi

    local archive_name="${vm}-$(get_compact_timestamp)"

    # Backup VM (XML config + any disks + extra files like NVRAM)
    if [ ${#disks[@]} -eq 0 ] && [ ${#block_disks[@]} -eq 0 ]; then
        log "Backing up VM $vm (XML config + extra files, no disks)"
        if [ "$DRY_RUN" = true ]; then
            log "[DRY-RUN] Would create archive $repo::$archive_name with XML and extra files"
        else
            $BORG create --verbose --stats --show-rc --compression "${BORG_COMPRESSION_VMS}" \
                "${repo}::${archive_name}" \
                "${xml_file}" "${extra_files[@]}"
        fi
    else
        log "Backing up VM $vm (XML config + disks + extra files)"
        if [ "$DRY_RUN" = true ]; then
            log "[DRY-RUN] Would create archive $repo::$archive_name with:"
            log "[DRY-RUN]   XML: $xml_file"
            for d in "${disks[@]}"; do
                log "[DRY-RUN]   Disk: $d"
            done
            for f in "${extra_files[@]}"; do
                log "[DRY-RUN]   Extra: $f"
            done
        else
            $BORG create --verbose --stats --show-rc --compression "${BORG_COMPRESSION_VMS}" \
                "${repo}::${archive_name}" \
                "${xml_file}" "${disks[@]}" "${extra_files[@]}"
        fi
    fi

    log "Pruning old backups for VM: $vm"
    if [ "$DRY_RUN" = true ]; then
        # shellcheck disable=SC2086
        log "[DRY-RUN] Would prune with: $BORG prune --list --glob-archives \"${vm}-*\" $BORG_PRUNE_KEEP \"$repo\""
    else
        # shellcheck disable=SC2086
        $BORG prune --list --glob-archives "${vm}-*" --show-rc $BORG_PRUNE_KEEP "${repo}"
    fi

    for disk in "${block_disks[@]}"; do
        log "Backing up block device: $disk"
        backup_physical_disk "$disk" "$vm" "$repo"
    done
}

# -----------------------------------------------------------------------------
# Main backup process
# -----------------------------------------------------------------------------

log "VM backup starting"

if [ "$DRY_RUN" = true ]; then
    log "Running in DRY-RUN mode - no changes will be made"
fi

# Validate Borg repository
if [ "$DRY_RUN" = true ]; then
    log "[DRY-RUN] Would validate repository: $BORG_REPO"
else
    validate_borg_repo "$BORG_REPO" "$BORG"
fi

# Create lock file
if ! create_pid_lock "$LOCK_FILE_VMS"; then
    error "Could not acquire lock - another backup may be running"
fi

# Get the list of all VMs
if [ -n "$VM_NAME_OVERRIDE" ]; then
    validate_vm_name "$VM_NAME_OVERRIDE"
    all_vms=("$VM_NAME_OVERRIDE")
else
    mapfile -t all_vms < <(virsh list --all --name | grep -v '^$')
fi

# Track which VMs were running so we can restart them at the end
declare -A vms_were_running

# First pass: shut down all VMs that need to be backed up
log "Shutting down VMs for backup..."
for vm in "${all_vms[@]}"; do
    if ! in_array "$vm" "${VM_EXCLUDE_LIST[@]:-}"; then
        # Check if the VM is running
        if [[ "$(virsh domstate "$vm")" == "running" ]]; then
            vms_were_running[$vm]=true
            if [ "$DRY_RUN" = true ]; then
                log "[DRY-RUN] Would shut down VM: $vm"
            else
                log "Shutting down VM: $vm"
                virsh shutdown "$vm"
            fi
        fi
    else
        log "Skipping excluded VM: $vm"
    fi
done

# Wait for all VMs to shut down
if [ "$DRY_RUN" != true ]; then
    log "Waiting for all VMs to shut down..."
    for vm in "${!vms_were_running[@]}"; do
        while [[ "$(virsh domstate "$vm")" != "shut off" ]]; do
            sleep 5
        done
        log "VM $vm is now shut off"
    done
fi

# Second pass: discover metadata for all VMs (runs once per VM)
log "Discovering VM metadata..."
for vm in "${all_vms[@]}"; do
    if ! in_array "$vm" "${VM_EXCLUDE_LIST[@]:-}"; then
        discover_vm "$vm"
    fi
done

# Third pass: backup all VMs to local repository
log "Starting local VM backups..."
for vm in "${all_vms[@]}"; do
    if ! in_array "$vm" "${VM_EXCLUDE_LIST[@]:-}"; then
        backup_vm_to_repo "$vm" "$BORG_REPO"
    fi
done

log "Local VM backups completed."

# Remote backup (if configured and server is available)
if [ -n "${REMOTE_BORG_REPO_VMS:-}" ] && [ -n "${REMOTE_HOST:-}" ]; then
    if is_remote_available "$REMOTE_HOST"; then
        log "Remote backup server is available, starting remote VM backups..."

        # Validate remote repo exists
        if [ "$DRY_RUN" = true ]; then
            log "[DRY-RUN] Would validate remote repository: $REMOTE_BORG_REPO_VMS"
            for vm in "${all_vms[@]}"; do
                if ! in_array "$vm" "${VM_EXCLUDE_LIST[@]:-}"; then
                    backup_vm_to_repo "$vm" "$REMOTE_BORG_REPO_VMS"
                fi
            done
            log "[DRY-RUN] Remote VM backups would complete"
        elif $BORG info "$REMOTE_BORG_REPO_VMS" &>/dev/null; then
            for vm in "${all_vms[@]}"; do
                if ! in_array "$vm" "${VM_EXCLUDE_LIST[@]:-}"; then
                    backup_vm_to_repo "$vm" "$REMOTE_BORG_REPO_VMS"
                fi
            done
            log "Remote VM backups completed."
        else
            warn "Remote repository not valid, skipping remote backup: $REMOTE_BORG_REPO_VMS"
        fi
    else
        log "Remote backup server not available, skipping remote VM backups"
    fi
fi

# Clean up cached metadata
log "Cleaning up temporary files..."
rm -rf "$BACKUP_TMP_DIR"

log "All VM backup operations completed."

# Restart VMs that were running before backup
log "Restarting VMs that were previously running..."
for vm in "${!vms_were_running[@]}"; do
    if [ "$DRY_RUN" = true ]; then
        log "[DRY-RUN] Would start VM: $vm"
    else
        log "Starting VM: $vm"
        virsh start "$vm"
    fi
done

log "Backup process completed."

# Remove lock file
remove_pid_lock "$LOCK_FILE_VMS"
