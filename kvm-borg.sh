#!/bin/bash

LOCKFILE="/var/run/backup_vms.lock"

# Function to log messages
log() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") - $1"
}

# Function to validate Borg repository
validate_borg_repo() {
    local repo=$1
    if [ -z "$repo" ]; then
        log "Error: No Borg repository specified."
        exit 1
    fi

    if ! borg info "$repo" &> /dev/null; then
        log "Error: The specified path is not a valid Borg repository: $repo"
        exit 1
    fi
}

# Function to validate VM name
validate_vm_name() {
    local vm=$1
    if ! virsh dominfo "$vm" &> /dev/null; then
        log "Error: The specified VM does not exist: $vm"
        exit 1
    fi
}

# Function to create a lock file
create_lock() {
    if [ -e "$LOCKFILE" ] && kill -0 "$(cat $LOCKFILE)"; then
        log "Another instance of the script is already running."
        exit 1
    fi
    echo $$ > "$LOCKFILE"
    trap 'rm -f "$LOCKFILE"; exit $?' INT TERM EXIT
}

# Function to remove the lock file
remove_lock() {
    rm -f "$LOCKFILE"
    trap - INT TERM EXIT
}

# Usage: ./backup_vms.sh /path/to/borg/repository [vm_name]

BORG_REPO=$1
VM_NAME=$2
BACKUP_TMP_DIR=/tmp/kvm_backup
EXCLUDE_LIST=( backup rfx3d thebutler ) # Add VM names to exclude here

# Borg settings
export BORG_PASSPHRASE='your_borg_passphrase'
BORG_ENCRYPTION_METHOD="repokey-blake2"
PRUNE_KEEP="--keep-daily 7 --keep-weekly 4 --keep-monthly 6"
COMP='zstd,5'

# Validate Borg repository
validate_borg_repo "$BORG_REPO"

# Create lock file
create_lock

# Function to backup a single VM
backup_vm() {
    local vm="$1"

    log "Backing up VM: $vm"

    local xml_file="$BACKUP_TMP_DIR/${vm}.xml"
    local disks=()
    local block_disks=()

    # Correctly parse both file and block disks
    while IFS= read -r line; do
        # Skip lines that are empty or have "-"
        if [[ -n "$line" && "$line" != "-" ]]; then
            if [[ "$line" == /dev/* ]]; then
                block_disks+=("$line")
            else
                disks+=("$line")
            fi
        fi
    done < <(virsh domblklist "${vm}" | tail -n +3 | awk '{print $2}')

    log "Dumping XML configuration for VM: $vm"
    mkdir -p "$BACKUP_TMP_DIR"
    virsh dumpxml "${vm}" > "${xml_file}"

    log "Disk paths for VM: $vm"
    for disk in "${disks[@]}"; do
        log "Disk: $disk"
    done

    log "Block device paths for VM: $vm"
    for disk in "${block_disks[@]}"; do
        log "Block Device: $disk"
    done

    log "Backing up disks for VM: $vm"
    borg create --verbose --stats --show-rc --compression "${COMP}" \
        "${BORG_REPO}::${vm}-$(date +%Y%m%d_%H%M%S)" \
        "${xml_file}" "${disks[@]/#/}"

    log "Pruning old backups for VM: $vm"
    borg prune --list --glob-archives "${vm}-*" --show-rc ${PRUNE_KEEP} "${BORG_REPO}"

    # Clean up temporary files
    rm -f "${xml_file}"

    # Backup block devices separately
    for disk in "${block_disks[@]}"; do
        log "Backing up block device: $disk"
        backup_physical_disk "$disk" "$vm"
    done
}

# Function to backup a physical disk
backup_physical_disk() {
    local disk="$1"
    local vm="$2"
    local partitions=()
    mapfile -t partitions < <(lsblk -o NAME,TYPE -p -n -l "$disk" | awk '$2 == "part" {print $1}')

    log "Backing up physical disk: $disk"

    if [[ ${#partitions[@]} -gt 0 ]]; then
        log "Handling partitions on physical disk: $disk"
        for partition in "${partitions[@]}"; do
            local fs_type
            fs_type=$(lsblk -f "$partition" -n -o FSTYPE)
            log "Backing up partition: $partition (FS type: $fs_type)"
            if [[ "$fs_type" == "ntfs" ]]; then
                log "Backing up NTFS partition: $partition"
                ntfsclone -so - "$partition" | borg create --verbose --stats --show-rc "${BORG_REPO}::${vm}-partition-$(basename "$partition")-$(date +%Y%m%d_%H%M%S)" -
            elif [[ "$fs_type" == ext* ]]; then
                log "Backing up ext* partition: $partition"
                zerofree "$partition"
                borg create --verbose --stats --show-rc --read-special "${BORG_REPO}::${vm}-partition-$(basename "$partition")-$(date +%Y%m%d_%H%M%S)" "$partition"
            else
                log "Backing up other partition type: $partition"
                borg create --verbose --stats --show-rc --read-special "${BORG_REPO}::${vm}-partition-$(basename "$partition")-$(date +%Y%m%d_%H%M%S)" "$partition"
            fi
        done
    else
        log "No partitions found, backing up whole disk: $disk"
        borg create --verbose --stats --show-rc --read-special "${BORG_REPO}::${vm}-disk-$(basename "$disk")-$(date +%Y%m%d_%H%M%S)" "$disk"
    fi
}

# Get the list of all VMs
if [ -z "$VM_NAME" ]; then
    all_vms=($(virsh list --all --name))
else
    validate_vm_name "$VM_NAME"
    all_vms=("$VM_NAME")
fi

# Backup each VM one by one
for vm in "${all_vms[@]}"; do
    if [[ ! " ${EXCLUDE_LIST[@]} " =~ " ${vm} " ]]; then
        was_running=false

        # Check if the VM is running
        if [[ "$(virsh domstate "$vm")" == "running" ]]; then
            was_running=true
            log "Shutting down VM: $vm"
            virsh shutdown "$vm"

            # Wait for the VM to shut down
            while [[ "$(virsh domstate "$vm")" != "shut off" ]]; do
                sleep 5
            done
        fi

        # Backup the VM
        backup_vm "$vm"

        # Restart the VM if it was running
        if $was_running; then
            log "Starting VM: $vm"
            virsh start "$vm"
        fi
    fi
done

log "Backup process completed."

# Remove lock file
remove_lock
