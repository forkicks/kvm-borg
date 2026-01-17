#!/bin/bash

# =============================================================================
# SYSTEM RESTORE SCRIPT
# =============================================================================
#
# Restores a complete system from a Borg backup to a new/replacement disk.
# Supports multiple host configurations with different partition layouts
# and boot modes.
#
# Usage scenarios:
#   1. LIVE USB: Boot any Linux live USB (Fedora, Ubuntu, Arch, etc.),
#      install borgbackup, and run this script.
#
#   2. CROSS-RESTORE: Connect disk to another server, run this script,
#      then physically move the disk to the target server.
#
# Prerequisites:
#   - Root access
#   - borgbackup installed (dnf install borgbackup / apt install borgbackup)
#   - Target disk must have NO partitions (safety requirement)
#   - For remote repo: SSH key access configured
#   - Required tools: parted, lvm2, xfsprogs, grub2, dosfstools (for UEFI)
#
# Configuration:
#   Host configurations are loaded from config/hosts/*.conf files.
#   Each host file defines boot mode, partition sizes, LVM settings, etc.
#
# =============================================================================

set -e

# Script location (resolve symlinks to find actual script directory)
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/../config"
HOSTS_DIR="$CONFIG_DIR/hosts"

# -----------------------------------------------------------------------------
# Terminal colors for status messages
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()     { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
prompt()  { echo -e "${CYAN}[INPUT]${NC} $1"; }
section() { echo -e "\n${BOLD}=== $1 ===${NC}\n"; }
detail()  { echo -e "    ${CYAN}->>${NC} $1"; }

# -----------------------------------------------------------------------------
# Host Configuration Loading
# -----------------------------------------------------------------------------

# List available host configurations
list_host_configs() {
    local configs=()
    if [ -d "$HOSTS_DIR" ]; then
        while IFS= read -r -d '' file; do
            configs+=("$(basename "$file" .conf)")
        done < <(find "$HOSTS_DIR" -maxdepth 1 -name "*.conf" -print0 2>/dev/null)
    fi

    # Also check /etc/kvm-borg/hosts
    if [ -d "/etc/kvm-borg/hosts" ]; then
        while IFS= read -r -d '' file; do
            local name
            name="$(basename "$file" .conf)"
            # Avoid duplicates
            local found=false
            for c in "${configs[@]}"; do
                if [ "$c" = "$name" ]; then
                    found=true
                    break
                fi
            done
            if [ "$found" = false ]; then
                configs+=("$name")
            fi
        done < <(find "/etc/kvm-borg/hosts" -maxdepth 1 -name "*.conf" -print0 2>/dev/null)
    fi

    printf '%s\n' "${configs[@]}"
}

# Load a host configuration by name
load_host_config() {
    local name="$1"
    local config_file=""

    # Check for config file
    if [ -f "$HOSTS_DIR/${name}.conf" ]; then
        config_file="$HOSTS_DIR/${name}.conf"
    elif [ -f "/etc/kvm-borg/hosts/${name}.conf" ]; then
        config_file="/etc/kvm-borg/hosts/${name}.conf"
    else
        return 1
    fi

    # Source the configuration
    # shellcheck source=/dev/null
    source "$config_file"
    return 0
}

# Validate loaded host configuration
validate_host_config() {
    local missing=()

    [ -z "${SYSTEM_NAME:-}" ] && missing+=("SYSTEM_NAME")
    [ -z "${BOOT_MODE:-}" ] && missing+=("BOOT_MODE")
    [ -z "${VG_NAME:-}" ] && missing+=("VG_NAME")
    [ -z "${BOOT_SIZE:-}" ] && missing+=("BOOT_SIZE")
    [ -z "${ROOT_SIZE:-}" ] && missing+=("ROOT_SIZE")
    [ -z "${SWAP_SIZE:-}" ] && missing+=("SWAP_SIZE")

    if [ "$BOOT_MODE" = "uefi" ] && [ -z "${EFI_SIZE:-}" ]; then
        missing+=("EFI_SIZE (required for UEFI)")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        echo "Missing required configuration: ${missing[*]}"
        return 1
    fi

    return 0
}

# -----------------------------------------------------------------------------
# STAGE 0: Pre-flight checks
# -----------------------------------------------------------------------------
section "STAGE 0: Pre-flight Checks"

echo "This stage verifies that all prerequisites are met before proceeding."
echo "We check for root access and required system tools."
echo ""

if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root. Use: sudo $0"
fi
log "Running as root: OK"

# List of required commands and what package typically provides them
declare -A REQUIRED_CMDS=(
    ["borg"]="borgbackup"
    ["parted"]="parted"
    ["pvcreate"]="lvm2"
    ["vgcreate"]="lvm2"
    ["lvcreate"]="lvm2"
    ["mkfs.xfs"]="xfsprogs"
    ["mkswap"]="util-linux"
)

echo ""
log "Checking for required commands..."
MISSING_CMDS=()
for cmd in "${!REQUIRED_CMDS[@]}"; do
    if command -v "$cmd" &>/dev/null; then
        detail "$cmd: found"
    else
        detail "$cmd: MISSING (install package: ${REQUIRED_CMDS[$cmd]})"
        MISSING_CMDS+=("$cmd")
    fi
done

if [ ${#MISSING_CMDS[@]} -gt 0 ]; then
    echo ""
    error "Missing required commands: ${MISSING_CMDS[*]}

Install them with your package manager, e.g.:
  Fedora/RHEL/Alma: dnf install borgbackup parted lvm2 xfsprogs grub2-tools dracut
  Debian/Ubuntu:    apt install borgbackup parted lvm2 xfsprogs grub2 dracut-core"
fi

log "All required commands found: OK"

# -----------------------------------------------------------------------------
# STAGE 1: Select Borg repository
# -----------------------------------------------------------------------------
section "STAGE 1: Select Borg Repository"

echo "Borg backup stores data in 'repositories'. Each repository contains"
echo "multiple 'archives' (point-in-time snapshots). We need to specify"
echo "which repository to restore from."
echo ""
echo "Enter the path to your Borg repository."
echo ""
echo "Examples:"
echo "  - Local path: /backup/system"
echo "  - Remote SSH: ssh://user@host/path/to/repo"
echo ""

prompt "Enter Borg repository path: "
read -r BORG_REPO

echo ""
log "Validating Borg repository accessibility..."
detail "Running: borg info \"$BORG_REPO\""
echo ""

if ! borg info "$BORG_REPO" 2>&1; then
    echo ""
    error "Cannot access Borg repository: $BORG_REPO

Troubleshooting:
  - For local repo: Is the disk mounted? Check: mount | grep backup
  - For remote repo: Can you SSH? Test: ssh <host> 'echo OK'
  - Is the path correct? List contents: ls -la <path>"
fi

echo ""
log "Repository validated successfully!"

# -----------------------------------------------------------------------------
# STAGE 2: Select system to restore
# -----------------------------------------------------------------------------
section "STAGE 2: Select System to Restore"

echo "This repository may contain archives from multiple systems."
echo "Each system has a different partition layout and boot configuration."
echo ""

# List available host configurations
mapfile -t available_hosts < <(list_host_configs)

if [ ${#available_hosts[@]} -eq 0 ]; then
    warn "No host configurations found in:"
    warn "  - $HOSTS_DIR"
    warn "  - /etc/kvm-borg/hosts"
    echo ""
    echo "You can create a host configuration interactively."
    echo ""
    prompt "Enter a system name (e.g., myserver): "
    read -r SYSTEM_NAME

    echo ""
    prompt "Description for this system: "
    read -r SYSTEM_DESC

    echo ""
    echo "Boot mode determines how the system starts."
    echo "  - bios: Traditional BIOS/Legacy boot (older systems, MBR)"
    echo "  - uefi: Modern UEFI boot (newer systems, GPT + EFI partition)"
    echo ""
    prompt "Boot mode (bios/uefi): "
    read -r BOOT_MODE

    if [ "$BOOT_MODE" = "uefi" ]; then
        prompt "EFI partition size (e.g., 600M): "
        read -r EFI_SIZE
        # Check for UEFI-specific tools
        if ! command -v mkfs.vfat &>/dev/null; then
            error "mkfs.vfat not found. Install dosfstools: dnf install dosfstools"
        fi
    else
        EFI_SIZE=""
    fi

    prompt "Boot partition size (e.g., 1G): "
    read -r BOOT_SIZE

    prompt "Root partition size (e.g., 100G): "
    read -r ROOT_SIZE

    prompt "Swap size (e.g., 4G): "
    read -r SWAP_SIZE

    prompt "Home partition size (leave empty for remaining space): "
    read -r HOME_SIZE

    prompt "LVM Volume Group name (e.g., almalinux): "
    read -r VG_NAME

    POST_RESTORE_NOTES=""
else
    echo "Available system configurations:"
    echo ""
    for i in "${!available_hosts[@]}"; do
        local host="${available_hosts[$i]}"
        echo "  $((i + 1))) $host"

        # Try to load and show description
        if load_host_config "$host" 2>/dev/null; then
            if [ -n "${SYSTEM_DESC:-}" ]; then
                echo "       $SYSTEM_DESC"
            fi
            echo "       Boot mode: ${BOOT_MODE:-unknown}"
        fi
        echo ""
    done

    echo "  $((${#available_hosts[@]} + 1))) Create new configuration"
    echo ""

    prompt "Select a system (number): "
    read -r system_choice

    if [ "$system_choice" -eq "$((${#available_hosts[@]} + 1))" ] 2>/dev/null; then
        # Create new configuration interactively
        prompt "Enter a system name (e.g., myserver): "
        read -r SYSTEM_NAME

        prompt "Description for this system: "
        read -r SYSTEM_DESC

        prompt "Boot mode (bios/uefi): "
        read -r BOOT_MODE

        if [ "$BOOT_MODE" = "uefi" ]; then
            prompt "EFI partition size (e.g., 600M): "
            read -r EFI_SIZE
            if ! command -v mkfs.vfat &>/dev/null; then
                error "mkfs.vfat not found. Install dosfstools"
            fi
        else
            EFI_SIZE=""
        fi

        prompt "Boot partition size (e.g., 1G): "
        read -r BOOT_SIZE

        prompt "Root partition size (e.g., 100G): "
        read -r ROOT_SIZE

        prompt "Swap size (e.g., 4G): "
        read -r SWAP_SIZE

        prompt "Home partition size (leave empty for remaining space): "
        read -r HOME_SIZE

        prompt "LVM Volume Group name (e.g., almalinux): "
        read -r VG_NAME

        POST_RESTORE_NOTES=""
    elif [ "$system_choice" -ge 1 ] && [ "$system_choice" -le "${#available_hosts[@]}" ] 2>/dev/null; then
        selected_host="${available_hosts[$((system_choice - 1))]}"
        if ! load_host_config "$selected_host"; then
            error "Failed to load configuration for: $selected_host"
        fi
        if ! validate_host_config; then
            error "Invalid host configuration"
        fi
    else
        error "Invalid selection"
    fi
fi

log "Selected system: ${SYSTEM_DESC:-$SYSTEM_NAME}"
log "Boot mode: $BOOT_MODE"
log "Volume group: $VG_NAME"

# Check for appropriate bootloader tools
echo ""
log "Checking bootloader tools for $BOOT_MODE mode..."

if [ "$BOOT_MODE" = "uefi" ]; then
    if command -v grub2-install &>/dev/null; then
        GRUB_INSTALL="grub2-install"
        GRUB_MKCONFIG="grub2-mkconfig"
        GRUB_CFG="/boot/grub2/grub.cfg"
    elif command -v grub-install &>/dev/null; then
        GRUB_INSTALL="grub-install"
        GRUB_MKCONFIG="grub-mkconfig"
        GRUB_CFG="/boot/grub/grub.cfg"
    else
        error "No GRUB installation tool found. Install grub2-efi-x64 or grub-efi-amd64"
    fi
else
    if command -v grub2-install &>/dev/null; then
        GRUB_INSTALL="grub2-install"
        GRUB_MKCONFIG="grub2-mkconfig"
        GRUB_CFG="/boot/grub2/grub.cfg"
    elif command -v grub-install &>/dev/null; then
        GRUB_INSTALL="grub-install"
        GRUB_MKCONFIG="grub-mkconfig"
        GRUB_CFG="/boot/grub/grub.cfg"
    else
        error "No GRUB installation tool found. Install grub2-tools or grub-pc"
    fi
fi
detail "Using: $GRUB_INSTALL"

# Check for dracut or update-initramfs
if command -v dracut &>/dev/null; then
    INITRAMFS_TOOL="dracut"
elif command -v update-initramfs &>/dev/null; then
    INITRAMFS_TOOL="update-initramfs"
else
    warn "No initramfs tool found. You may need to rebuild initramfs manually."
    INITRAMFS_TOOL=""
fi
if [ -n "$INITRAMFS_TOOL" ]; then
    detail "Initramfs tool: $INITRAMFS_TOOL"
fi

# -----------------------------------------------------------------------------
# STAGE 3: Select archive to restore
# -----------------------------------------------------------------------------
section "STAGE 3: Select Archive to Restore"

echo "Each Borg repository contains multiple archives. Archives are named"
echo "with the source hostname prefix, e.g., 'hostname-2025-12-25-030000'."
echo ""
echo "Listing archives for $SYSTEM_NAME (most recent 15):"
echo ""

borg list "$BORG_REPO" --glob-archives "${SYSTEM_NAME}-*" 2>/dev/null | tail -15

ARCHIVE_COUNT=$(borg list "$BORG_REPO" --glob-archives "${SYSTEM_NAME}-*" 2>/dev/null | wc -l)
if [ "$ARCHIVE_COUNT" -eq 0 ]; then
    echo ""
    warn "No archives found for '${SYSTEM_NAME}-*' pattern."
    echo ""
    echo "Showing all archives instead:"
    borg list "$BORG_REPO" | tail -15
fi

echo ""
echo "Choose which archive to restore. Typically you want the most recent"
echo "one, unless you're recovering from a problem introduced in recent backups."
echo ""

prompt "Enter the full archive name to restore: "
read -r ARCHIVE_NAME

echo ""
log "Validating archive exists..."
detail "Running: borg info \"$BORG_REPO::$ARCHIVE_NAME\""
echo ""

if ! borg info "$BORG_REPO::$ARCHIVE_NAME" 2>&1; then
    echo ""
    error "Archive not found: $ARCHIVE_NAME

Check the archive name carefully - it must match exactly.
List archives again with: borg list \"$BORG_REPO\""
fi

echo ""
log "Archive validated: $ARCHIVE_NAME"

# -----------------------------------------------------------------------------
# STAGE 4: Select target device
# -----------------------------------------------------------------------------
section "STAGE 4: Select Target Device"

echo "Now we need to select the target disk where the system will be restored."
echo "This should be a blank disk (new or wiped) with NO existing partitions."
echo ""
echo "CRITICAL: All data on the selected disk will be DESTROYED!"
echo ""
echo "Available block devices:"
echo ""
lsblk -d -o NAME,SIZE,TYPE,MODEL,SERIAL | grep -E "NAME|disk"
echo ""

if [ "$BOOT_MODE" = "uefi" ]; then
    echo "For UEFI systems, a SATA SSD is typical: /dev/sda"
else
    echo "For BIOS systems, an NVMe drive is typical: /dev/nvme0n1"
fi
echo ""
echo "DO NOT select:"
echo "  - The disk containing this live environment"
echo "  - Any disk with data you want to keep"
echo "  - Disks containing ZFS pools or backup data"
echo ""

prompt "Enter target device (e.g., /dev/nvme0n1 or /dev/sda): "
read -r TARGET_DEVICE

# Validate device exists
if [ ! -b "$TARGET_DEVICE" ]; then
    error "Device not found: $TARGET_DEVICE

This doesn't appear to be a valid block device.
List available devices with: lsblk -d"
fi

log "Device exists: $TARGET_DEVICE"

# Safety check: ensure no partitions exist
echo ""
log "Checking for existing partitions (safety check)..."
echo ""

PARTITION_COUNT=$(lsblk -n "$TARGET_DEVICE" | wc -l)
if [ "$PARTITION_COUNT" -gt 1 ]; then
    echo "Current partition layout of $TARGET_DEVICE:"
    lsblk "$TARGET_DEVICE"
    echo ""
    error "Target device has existing partitions!

For safety, this script requires a blank disk with NO partitions.
This prevents accidentally overwriting the wrong disk.

To wipe the disk (DESTROYS ALL DATA), run:
  wipefs -a $TARGET_DEVICE

Then re-run this script."
fi

log "No partitions found on $TARGET_DEVICE: OK (safe to proceed)"

# Determine partition naming convention
if [[ "$TARGET_DEVICE" == *"nvme"* ]] || [[ "$TARGET_DEVICE" == *"loop"* ]]; then
    PART_PREFIX="${TARGET_DEVICE}p"
    detail "NVMe/loop device detected - partitions will use 'p' suffix"
else
    PART_PREFIX="${TARGET_DEVICE}"
    detail "SATA/SAS device detected - partitions will use numeric suffix"
fi

# Set partition device names based on boot mode
if [ "$BOOT_MODE" = "uefi" ]; then
    PART_EFI="${PART_PREFIX}1"
    PART_BOOT="${PART_PREFIX}2"
    PART_LVM="${PART_PREFIX}3"
else
    PART_BOOT="${PART_PREFIX}1"
    PART_LVM="${PART_PREFIX}2"
fi

# -----------------------------------------------------------------------------
# STAGE 5: Final confirmation
# -----------------------------------------------------------------------------
section "STAGE 5: Final Confirmation"

echo "Please review the restoration plan carefully:"
echo ""
echo "┌─────────────────────────────────────────────────────────────────────┐"
echo "│  RESTORATION SUMMARY                                                │"
echo "├─────────────────────────────────────────────────────────────────────┤"
printf "│  %-67s │\n" "System:            ${SYSTEM_DESC:-$SYSTEM_NAME}"
printf "│  %-67s │\n" "Source Repository: $BORG_REPO"
printf "│  %-67s │\n" "Source Archive:    $ARCHIVE_NAME"
printf "│  %-67s │\n" "Target Device:     $TARGET_DEVICE"
printf "│  %-67s │\n" "Boot Mode:         $BOOT_MODE"
echo "├─────────────────────────────────────────────────────────────────────┤"
echo "│  PARTITION LAYOUT TO BE CREATED:                                    │"
echo "│                                                                     │"

if [ "$BOOT_MODE" = "uefi" ]; then
    printf "│    %-63s │\n" "$PART_EFI: ${EFI_SIZE} EFI System Partition (FAT32)"
    printf "│    %-63s │\n" "$PART_BOOT: ${BOOT_SIZE} /boot (XFS)"
    printf "│    %-63s │\n" "$PART_LVM: LVM physical volume (remaining space)"
else
    printf "│    %-63s │\n" "$PART_BOOT: ${BOOT_SIZE} /boot (XFS)"
    printf "│    %-63s │\n" "$PART_LVM: LVM physical volume (remaining space)"
fi

echo "│                                                                     │"
echo "│  LVM LOGICAL VOLUMES:                                               │"
echo "│                                                                     │"
printf "│    %-63s │\n" "${VG_NAME}-root: ${ROOT_SIZE} mounted at / (XFS)"
printf "│    %-63s │\n" "${VG_NAME}-swap: ${SWAP_SIZE} swap space"
if [ -n "$HOME_SIZE" ]; then
    printf "│    %-63s │\n" "${VG_NAME}-home: ${HOME_SIZE} mounted at /home (XFS)"
else
    printf "│    %-63s │\n" "${VG_NAME}-home: remaining space at /home (XFS)"
fi
echo "│                                                                     │"
echo "└─────────────────────────────────────────────────────────────────────┘"
echo ""
echo -e "${RED}${BOLD}WARNING: ALL DATA ON $TARGET_DEVICE WILL BE PERMANENTLY DESTROYED!${NC}"
echo ""

prompt "Type 'YES' (all caps) to proceed with restoration: "
read -r confirm

if [ "$confirm" != "YES" ]; then
    error "Aborted by user. No changes were made."
fi

echo ""
log "Confirmation received. Beginning restoration process..."
echo ""

# -----------------------------------------------------------------------------
# STAGE 6: Create partition table and partitions
# -----------------------------------------------------------------------------
section "STAGE 6: Create Partitions"

echo "This stage creates the partition layout on the target disk."
echo ""

if [ "$BOOT_MODE" = "uefi" ]; then
    echo "For UEFI boot, we will create:"
    echo "  1. A GPT partition table"
    echo "  2. An EFI System Partition (ESP) for UEFI bootloader"
    echo "  3. A /boot partition for kernel and initramfs"
    echo "  4. An LVM partition for /, /home, and swap"
else
    echo "For BIOS boot, we will create:"
    echo "  1. A GPT partition table"
    echo "  2. A /boot partition for kernel and initramfs"
    echo "  3. An LVM partition for /, /home, and swap"
fi
echo ""

log "Creating GPT partition table on $TARGET_DEVICE..."
detail "Running: parted -s $TARGET_DEVICE mklabel gpt"
echo ""

parted -s "$TARGET_DEVICE" mklabel gpt
log "GPT partition table created"

if [ "$BOOT_MODE" = "uefi" ]; then
    # UEFI: Create EFI, boot, and LVM partitions
    echo ""
    log "Creating EFI System Partition ($EFI_SIZE)..."
    detail "Running: parted -s $TARGET_DEVICE mkpart primary fat32 1MiB $EFI_SIZE"
    detail "Running: parted -s $TARGET_DEVICE set 1 esp on"
    echo ""

    parted -s "$TARGET_DEVICE" mkpart primary fat32 1MiB "$EFI_SIZE"
    parted -s "$TARGET_DEVICE" set 1 esp on
    log "EFI partition created: $PART_EFI"

    echo ""
    log "Creating boot partition ($BOOT_SIZE)..."
    BOOT_START="$EFI_SIZE"
    BOOT_END="$((${EFI_SIZE%M} + ${BOOT_SIZE%G} * 1024))M"
    detail "Running: parted -s $TARGET_DEVICE mkpart primary xfs $BOOT_START $BOOT_END"
    echo ""

    parted -s "$TARGET_DEVICE" mkpart primary xfs "$BOOT_START" "$BOOT_END"
    log "Boot partition created: $PART_BOOT"

    echo ""
    log "Creating LVM partition (remaining space)..."
    detail "Running: parted -s $TARGET_DEVICE mkpart primary $BOOT_END 100%"
    detail "Running: parted -s $TARGET_DEVICE set 3 lvm on"
    echo ""

    parted -s "$TARGET_DEVICE" mkpart primary "$BOOT_END" 100%
    parted -s "$TARGET_DEVICE" set 3 lvm on
    log "LVM partition created: $PART_LVM"
else
    # BIOS: Create boot and LVM partitions
    echo ""
    log "Creating boot partition ($BOOT_SIZE)..."
    detail "Running: parted -s $TARGET_DEVICE mkpart primary xfs 1MiB $BOOT_SIZE"
    detail "Running: parted -s $TARGET_DEVICE set 1 boot on"
    echo ""

    parted -s "$TARGET_DEVICE" mkpart primary xfs 1MiB "$BOOT_SIZE"
    parted -s "$TARGET_DEVICE" set 1 boot on
    log "Boot partition created: $PART_BOOT"

    echo ""
    log "Creating LVM partition (remaining space)..."
    detail "Running: parted -s $TARGET_DEVICE mkpart primary $BOOT_SIZE 100%"
    detail "Running: parted -s $TARGET_DEVICE set 2 lvm on"
    echo ""

    parted -s "$TARGET_DEVICE" mkpart primary "$BOOT_SIZE" 100%
    parted -s "$TARGET_DEVICE" set 2 lvm on
    log "LVM partition created: $PART_LVM"
fi

echo ""
log "Waiting for kernel to recognize new partitions..."
detail "Running: partprobe $TARGET_DEVICE"
echo ""

sleep 2
partprobe "$TARGET_DEVICE"
sleep 2

# Verify partitions were created
if [ "$BOOT_MODE" = "uefi" ]; then
    if [ ! -b "$PART_EFI" ] || [ ! -b "$PART_BOOT" ] || [ ! -b "$PART_LVM" ]; then
        error "Partitions were not created properly.

Expected: $PART_EFI, $PART_BOOT, and $PART_LVM
Actual:
$(lsblk $TARGET_DEVICE)

MANUAL FIX: You may need to run 'partprobe $TARGET_DEVICE' or reboot."
    fi
else
    if [ ! -b "$PART_BOOT" ] || [ ! -b "$PART_LVM" ]; then
        error "Partitions were not created properly.

Expected: $PART_BOOT and $PART_LVM
Actual:
$(lsblk $TARGET_DEVICE)

MANUAL FIX: You may need to run 'partprobe $TARGET_DEVICE' or reboot."
    fi
fi

log "Partitions created successfully!"
echo ""
lsblk "$TARGET_DEVICE"

# -----------------------------------------------------------------------------
# STAGE 7: Set up LVM
# -----------------------------------------------------------------------------
section "STAGE 7: Set Up LVM (Logical Volume Manager)"

echo "LVM provides flexible disk management. We create:"
echo "  - Physical Volume (PV): The raw partition used by LVM"
echo "  - Volume Group (VG): A pool of storage named '$VG_NAME'"
echo "  - Logical Volumes (LV): Virtual partitions for root, swap, and home"
echo ""

log "Creating LVM physical volume on $PART_LVM..."
detail "Running: pvcreate -ff $PART_LVM"
echo ""

pvcreate -ff "$PART_LVM"
log "Physical volume created"

echo ""
log "Creating volume group: $VG_NAME..."
detail "Running: vgcreate $VG_NAME $PART_LVM"
echo ""

vgcreate "$VG_NAME" "$PART_LVM"
log "Volume group created: $VG_NAME"

echo ""
log "Creating logical volume for root filesystem ($ROOT_SIZE)..."
detail "Running: lvcreate -L $ROOT_SIZE -n root $VG_NAME"
echo ""

lvcreate -L "$ROOT_SIZE" -n root "$VG_NAME"
log "Created: /dev/$VG_NAME/root ($ROOT_SIZE)"

echo ""
log "Creating logical volume for swap ($SWAP_SIZE)..."
detail "Running: lvcreate -L $SWAP_SIZE -n swap $VG_NAME"
echo ""

lvcreate -L "$SWAP_SIZE" -n swap "$VG_NAME"
log "Created: /dev/$VG_NAME/swap ($SWAP_SIZE)"

echo ""
if [ -n "$HOME_SIZE" ]; then
    log "Creating logical volume for home ($HOME_SIZE)..."
    detail "Running: lvcreate -L $HOME_SIZE -n home $VG_NAME"
    lvcreate -L "$HOME_SIZE" -n home "$VG_NAME"
else
    log "Creating logical volume for home (remaining space)..."
    detail "Running: lvcreate -l 100%FREE -n home $VG_NAME"
    lvcreate -l 100%FREE -n home "$VG_NAME"
fi
echo ""
log "Created: /dev/$VG_NAME/home"

echo ""
log "LVM setup complete. Current configuration:"
echo ""
pvs
echo ""
vgs
echo ""
lvs

# -----------------------------------------------------------------------------
# STAGE 8: Format filesystems
# -----------------------------------------------------------------------------
section "STAGE 8: Format Filesystems"

echo "Now we create filesystems on each partition/volume."
echo ""

if [ "$BOOT_MODE" = "uefi" ]; then
    log "Formatting EFI partition as FAT32..."
    detail "Running: mkfs.vfat -F 32 $PART_EFI"
    echo ""

    mkfs.vfat -F 32 "$PART_EFI"
    log "Formatted: $PART_EFI (FAT32)"
    echo ""
fi

log "Formatting /boot partition as XFS..."
detail "Running: mkfs.xfs -f $PART_BOOT"
echo ""

mkfs.xfs -f "$PART_BOOT"
log "Formatted: $PART_BOOT (XFS)"

echo ""
log "Formatting root volume as XFS..."
detail "Running: mkfs.xfs -f /dev/$VG_NAME/root"
echo ""

mkfs.xfs -f "/dev/$VG_NAME/root"
log "Formatted: /dev/$VG_NAME/root (XFS)"

echo ""
log "Formatting home volume as XFS..."
detail "Running: mkfs.xfs -f /dev/$VG_NAME/home"
echo ""

mkfs.xfs -f "/dev/$VG_NAME/home"
log "Formatted: /dev/$VG_NAME/home (XFS)"

echo ""
log "Creating swap space..."
detail "Running: mkswap /dev/$VG_NAME/swap"
echo ""

mkswap "/dev/$VG_NAME/swap"
log "Swap space created: /dev/$VG_NAME/swap"

echo ""
log "All filesystems created successfully!"

# -----------------------------------------------------------------------------
# STAGE 9: Mount filesystems
# -----------------------------------------------------------------------------
section "STAGE 9: Mount Filesystems"

MOUNT_ROOT="/mnt/restore"

echo "Before we can extract the backup, we need to mount all filesystems"
echo "in a temporary location that mirrors the final directory structure."
echo ""

log "Creating mount point: $MOUNT_ROOT"
mkdir -p "$MOUNT_ROOT"

echo ""
log "Mounting root filesystem..."
detail "Running: mount /dev/$VG_NAME/root $MOUNT_ROOT"
echo ""

mount "/dev/$VG_NAME/root" "$MOUNT_ROOT"
log "Mounted: /dev/$VG_NAME/root -> $MOUNT_ROOT"

echo ""
log "Creating subdirectories and mounting remaining filesystems..."

mkdir -p "$MOUNT_ROOT/boot" "$MOUNT_ROOT/home"

if [ "$BOOT_MODE" = "uefi" ]; then
    mkdir -p "$MOUNT_ROOT/boot/efi"
fi

detail "Running: mount $PART_BOOT $MOUNT_ROOT/boot"
mount "$PART_BOOT" "$MOUNT_ROOT/boot"
log "Mounted: $PART_BOOT -> $MOUNT_ROOT/boot"

if [ "$BOOT_MODE" = "uefi" ]; then
    mkdir -p "$MOUNT_ROOT/boot/efi"
    detail "Running: mount $PART_EFI $MOUNT_ROOT/boot/efi"
    mount "$PART_EFI" "$MOUNT_ROOT/boot/efi"
    log "Mounted: $PART_EFI -> $MOUNT_ROOT/boot/efi"
fi

detail "Running: mount /dev/$VG_NAME/home $MOUNT_ROOT/home"
mount "/dev/$VG_NAME/home" "$MOUNT_ROOT/home"
log "Mounted: /dev/$VG_NAME/home -> $MOUNT_ROOT/home"

echo ""
log "All filesystems mounted. Current mount status:"
echo ""
df -h "$MOUNT_ROOT" "$MOUNT_ROOT/boot" "$MOUNT_ROOT/home"

# -----------------------------------------------------------------------------
# STAGE 10: Extract Borg archive
# -----------------------------------------------------------------------------
section "STAGE 10: Extract Borg Archive"

echo "This is the main restoration step. Borg will extract all files from"
echo "the selected archive to the mounted filesystems."
echo ""
echo "IMPORTANT: This may take a long time depending on:"
echo "  - Size of the backup"
echo "  - Speed of the source (local disk vs network)"
echo "  - Speed of the target disk"
echo ""

log "Beginning Borg extraction..."
detail "Running: cd $MOUNT_ROOT && borg extract --progress \"$BORG_REPO::$ARCHIVE_NAME\""
echo ""

cd "$MOUNT_ROOT"
borg extract --progress "$BORG_REPO::$ARCHIVE_NAME"
cd /

echo ""
log "Borg extraction completed successfully!"

# -----------------------------------------------------------------------------
# STAGE 11: Update fstab
# -----------------------------------------------------------------------------
section "STAGE 11: Update /etc/fstab"

echo "The /etc/fstab file tells Linux which filesystems to mount at boot."
echo "We need to update it with new UUIDs for the new partitions."
echo ""

log "Getting new UUIDs..."
BOOT_UUID=$(blkid -s UUID -o value "$PART_BOOT")
detail "Boot partition UUID: $BOOT_UUID"

if [ "$BOOT_MODE" = "uefi" ]; then
    EFI_UUID=$(blkid -s UUID -o value "$PART_EFI")
    detail "EFI partition UUID: $EFI_UUID"
fi

echo ""
log "Creating new /etc/fstab..."

if [ "$BOOT_MODE" = "uefi" ]; then
    cat > "$MOUNT_ROOT/etc/fstab" << EOF
# /etc/fstab - Filesystem Table
# Generated by restore-system.sh on $(date)
# System: ${SYSTEM_DESC:-$SYSTEM_NAME}

# Root filesystem (LVM)
/dev/mapper/${VG_NAME}-root /                       xfs     defaults        0 0

# Boot partition
UUID=$BOOT_UUID /boot                   xfs     defaults        0 0

# EFI System Partition
UUID=$EFI_UUID          /boot/efi               vfat    umask=0077,shortname=winnt 0 2

# Home filesystem (LVM)
/dev/mapper/${VG_NAME}-home /home                   xfs     defaults        0 0

# Swap (LVM)
/dev/mapper/${VG_NAME}-swap none                    swap    defaults        0 0
EOF
else
    cat > "$MOUNT_ROOT/etc/fstab" << EOF
# /etc/fstab - Filesystem Table
# Generated by restore-system.sh on $(date)
# System: ${SYSTEM_DESC:-$SYSTEM_NAME}

# Root filesystem (LVM)
/dev/mapper/${VG_NAME}-root /                       xfs     defaults        0 0

# Boot partition
UUID=$BOOT_UUID /boot                   xfs     defaults        0 0

# Home filesystem (LVM)
/dev/mapper/${VG_NAME}-home /home                   xfs     defaults        0 0

# Swap (LVM)
/dev/mapper/${VG_NAME}-swap none                    swap    defaults        0 0
EOF
fi

log "New /etc/fstab created"
echo ""
echo "Contents of new /etc/fstab:"
echo "----------------------------"
cat "$MOUNT_ROOT/etc/fstab"
echo "----------------------------"

# -----------------------------------------------------------------------------
# STAGE 12: Prepare chroot environment
# -----------------------------------------------------------------------------
section "STAGE 12: Prepare Chroot Environment"

echo "To install the bootloader, we need to 'chroot' into the restored system."
echo "This makes commands run as if we had booted into the restored system."
echo ""

log "Bind-mounting virtual filesystems..."

mount --bind /dev "$MOUNT_ROOT/dev"
log "Mounted: /dev"

mount --bind /dev/pts "$MOUNT_ROOT/dev/pts"
log "Mounted: /dev/pts"

mount --bind /proc "$MOUNT_ROOT/proc"
log "Mounted: /proc"

mount --bind /sys "$MOUNT_ROOT/sys"
log "Mounted: /sys"

mount --bind /run "$MOUNT_ROOT/run"
log "Mounted: /run"

# For UEFI, also mount efivars if available
if [ "$BOOT_MODE" = "uefi" ] && [ -d /sys/firmware/efi/efivars ]; then
    mount --bind /sys/firmware/efi/efivars "$MOUNT_ROOT/sys/firmware/efi/efivars" 2>/dev/null || true
    log "Mounted: /sys/firmware/efi/efivars (for UEFI)"
fi

echo ""
log "Chroot environment ready"

# -----------------------------------------------------------------------------
# STAGE 13: Install bootloader (GRUB)
# -----------------------------------------------------------------------------
section "STAGE 13: Install Bootloader (GRUB)"

if [ "$BOOT_MODE" = "uefi" ]; then
    echo "Installing GRUB for UEFI boot mode."
    echo ""

    log "Installing GRUB for UEFI..."
    detail "Running: chroot $MOUNT_ROOT $GRUB_INSTALL --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=almalinux"
    echo ""

    chroot "$MOUNT_ROOT" /bin/bash -c "$GRUB_INSTALL --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=almalinux"
    log "GRUB installed to EFI partition"
else
    echo "Installing GRUB for BIOS/Legacy boot mode."
    echo ""

    log "Installing GRUB to $TARGET_DEVICE..."
    detail "Running: chroot $MOUNT_ROOT $GRUB_INSTALL $TARGET_DEVICE"
    echo ""

    chroot "$MOUNT_ROOT" /bin/bash -c "$GRUB_INSTALL $TARGET_DEVICE"
    log "GRUB installed to boot sector"
fi

echo ""
log "Generating GRUB configuration..."
detail "Running: chroot $MOUNT_ROOT $GRUB_MKCONFIG -o $GRUB_CFG"
echo ""

chroot "$MOUNT_ROOT" /bin/bash -c "$GRUB_MKCONFIG -o $GRUB_CFG"
log "GRUB configuration generated"

# -----------------------------------------------------------------------------
# STAGE 14: Rebuild initramfs
# -----------------------------------------------------------------------------
section "STAGE 14: Rebuild Initramfs"

echo "The initramfs contains drivers and scripts needed to mount the root"
echo "filesystem at boot. We rebuild it to ensure LVM modules are included."
echo ""

if [ -z "$INITRAMFS_TOOL" ]; then
    warn "No initramfs tool found. Skipping rebuild."
    warn "You may need to rebuild manually after booting."
else
    log "Finding installed kernel version..."
    KERNEL_VERSION=$(ls "$MOUNT_ROOT/lib/modules" | sort -V | tail -1)
    detail "Kernel version: $KERNEL_VERSION"

    if [ -n "$KERNEL_VERSION" ]; then
        echo ""
        log "Rebuilding initramfs for kernel $KERNEL_VERSION..."

        if [ "$INITRAMFS_TOOL" = "dracut" ]; then
            detail "Running: chroot $MOUNT_ROOT dracut -f /boot/initramfs-${KERNEL_VERSION}.img ${KERNEL_VERSION}"
            chroot "$MOUNT_ROOT" /bin/bash -c "dracut -f /boot/initramfs-${KERNEL_VERSION}.img ${KERNEL_VERSION}"
        else
            detail "Running: chroot $MOUNT_ROOT update-initramfs -u -k ${KERNEL_VERSION}"
            chroot "$MOUNT_ROOT" /bin/bash -c "update-initramfs -u -k ${KERNEL_VERSION}"
        fi

        log "Initramfs rebuilt successfully"
    else
        warn "Could not determine kernel version - skipping initramfs rebuild"
    fi
fi

# -----------------------------------------------------------------------------
# STAGE 15: Cleanup
# -----------------------------------------------------------------------------
section "STAGE 15: Cleanup"

echo "Unmounting all filesystems in reverse order..."
echo ""

log "Unmounting virtual filesystems..."
if [ "$BOOT_MODE" = "uefi" ] && [ -d "$MOUNT_ROOT/sys/firmware/efi/efivars" ]; then
    umount "$MOUNT_ROOT/sys/firmware/efi/efivars" 2>/dev/null || true
fi
umount "$MOUNT_ROOT/dev/pts" 2>/dev/null || warn "Could not unmount /dev/pts"
umount "$MOUNT_ROOT/dev" 2>/dev/null || warn "Could not unmount /dev"
umount "$MOUNT_ROOT/proc" 2>/dev/null || warn "Could not unmount /proc"
umount "$MOUNT_ROOT/sys" 2>/dev/null || warn "Could not unmount /sys"
umount "$MOUNT_ROOT/run" 2>/dev/null || warn "Could not unmount /run"

log "Unmounting data filesystems..."
if [ "$BOOT_MODE" = "uefi" ]; then
    umount "$MOUNT_ROOT/boot/efi" || warn "Could not unmount /boot/efi"
fi
umount "$MOUNT_ROOT/boot" || warn "Could not unmount /boot"
umount "$MOUNT_ROOT/home" || warn "Could not unmount /home"
umount "$MOUNT_ROOT" || warn "Could not unmount root"

log "Deactivating LVM volume group..."
detail "Running: vgchange -an $VG_NAME"
vgchange -an "$VG_NAME" 2>/dev/null || true

log "Cleanup complete"

# -----------------------------------------------------------------------------
# STAGE 16: Complete!
# -----------------------------------------------------------------------------
section "RESTORATION COMPLETE!"

echo -e "${GREEN}${BOLD}"
echo "╔═══════════════════════════════════════════════════════════════════════╗"
echo "║                    SYSTEM RESTORATION SUCCESSFUL!                      ║"
echo "╚═══════════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo ""
echo "System restored: ${SYSTEM_DESC:-$SYSTEM_NAME}"
echo "Target device:   $TARGET_DEVICE"
echo "Boot mode:       $BOOT_MODE"
echo ""
echo "┌─────────────────────────────────────────────────────────────────────────┐"
echo "│  NEXT STEPS                                                             │"
echo "├─────────────────────────────────────────────────────────────────────────┤"
echo "│                                                                         │"
echo "│  1. If restored on a DIFFERENT server:                                  │"
echo "│     - Shut down this server                                             │"
echo "│     - Move $TARGET_DEVICE to the target server"
echo "│     - Boot the target server                                            │"
echo "│                                                                         │"
echo "│  2. If restored on the TARGET server (from live USB):                   │"
echo "│     - Remove the live USB                                               │"
echo "│     - Reboot: reboot                                                    │"
echo "│                                                                         │"

if [ -n "${POST_RESTORE_NOTES:-}" ]; then
    echo "├─────────────────────────────────────────────────────────────────────────┤"
    echo "│  SYSTEM-SPECIFIC NOTES                                                  │"
    echo "├─────────────────────────────────────────────────────────────────────────┤"
    echo "$POST_RESTORE_NOTES"
fi

echo "│                                                                         │"
echo "│  General checks after boot:                                             │"
echo "│    - Verify services: systemctl --failed                                │"
echo "│    - Check network connectivity                                         │"
echo "│    - Verify storage mounts: df -h                                       │"
echo "│                                                                         │"
echo "└─────────────────────────────────────────────────────────────────────────┘"
echo ""
log "Good luck!"
echo ""
