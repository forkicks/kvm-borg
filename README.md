# kvm-borg

A comprehensive backup solution for Linux systems and KVM virtual machines using [BorgBackup](https://borgbackup.readthedocs.io/).

> **WARNING: USE AT YOUR OWN RISK**
>
> This software is provided "as is", without warranty of any kind, express or implied. The authors assume no liability for data loss, system damage, or any other issues arising from the use of these scripts. Always test with `--dry-run` first and verify your backups regularly.

## Features

- **System Backup**: Full filesystem backup with configurable excludes
- **VM Backup**: KVM/libvirt VM backup including disks, XML configs, and NVRAM
- **Database Backup**: MySQL/MariaDB and PostgreSQL support
- **System Restore**: Interactive restore script with multi-host support
- **Remote Backup**: Optional remote repository synchronization
- **Service Management**: Graceful container/service stop/start during backups
- **Dry Run Mode**: Preview operations without making changes

## Quick Start

### 1. Install Dependencies

```bash
# Fedora/RHEL/AlmaLinux
dnf install borgbackup

# Debian/Ubuntu
apt install borgbackup
```

### 2. Create Configuration

```bash
# System-wide installation (recommended)
sudo mkdir -p /etc/kvm-borg
sudo cp config/backup.conf.example /etc/kvm-borg/backup.conf
sudo chmod 600 /etc/kvm-borg/backup.conf

# Edit configuration
sudo nano /etc/kvm-borg/backup.conf
```

### 3. Initialize Borg Repositories

```bash
# System backup repository
borg init --encryption=repokey-blake2 /backup/system

# VM backup repository
borg init --encryption=repokey-blake2 /backup/kvm
```

### 4. Run Backups

```bash
# System backup
./scripts/backup-system.sh

# VM backup
./scripts/backup-vms.sh

# Database backup
./scripts/backup-database.sh
```

## Repository Structure

```
kvm-borg/
├── README.md                      # This file
├── config/
│   ├── backup.conf.example        # Main configuration template
│   └── hosts/
│       ├── example-bios.conf      # BIOS server restore config
│       └── example-uefi.conf      # UEFI server restore config
├── scripts/
│   ├── backup-system.sh           # Full system backup
│   ├── backup-vms.sh              # KVM VM backup
│   ├── backup-database.sh         # Database backup (MySQL/PostgreSQL)
│   ├── restore-system.sh          # Interactive system restore
│   └── lib/
│       └── common.sh              # Shared functions
└── examples/
    └── crontab.example            # Example cron entries
```

## Configuration

### Main Configuration (`backup.conf`)

The main configuration file controls all backup scripts. Copy `config/backup.conf.example` to one of:

- `/etc/kvm-borg/backup.conf` (recommended for production)
- `config/backup.conf` (relative to repository)
- Custom path via `BACKUP_CONF` environment variable

Key settings:

```bash
# Borg repositories
BORG_REPO_SYSTEM="/backup/system"
BORG_REPO_VMS="/backup/kvm"

# Remote backup (optional)
REMOTE_HOST="backup-server.local"
REMOTE_BORG_REPO_SYSTEM="ssh://backup-server/repos/system"
REMOTE_BORG_REPO_VMS="ssh://backup-server/repos/kvm"

# Services to stop during backup
CONTAINERS=("mariadb" "gitea" "plex")
CONTAINERS_DELAYED_START=("jellyfin")

# VM exclude list
VM_EXCLUDE_LIST=("template-vm" "test-vm")

# System excludes
CUSTOM_EXCLUDES=(
    "/var/log/audit"
    "/home/*/Downloads"
)
```

### Host Configuration (for restore)

Create host-specific configurations in `config/hosts/` for system restore:

```bash
# config/hosts/myserver.conf
SYSTEM_NAME="myserver"
SYSTEM_DESC="My Production Server"
BOOT_MODE="bios"     # or "uefi"
VG_NAME="almalinux"
BOOT_SIZE="1G"
ROOT_SIZE="100G"
SWAP_SIZE="4G"
HOME_SIZE=""         # Empty = remaining space
```

### Environment Variable Overrides

All configuration values can be overridden with environment variables:

```bash
BORG_REPO_SYSTEM=/custom/path ./scripts/backup-system.sh
```

## Scripts

### backup-system.sh

Performs a full system backup to local and optionally remote Borg repositories.

```bash
# Basic usage
./scripts/backup-system.sh

# Include VM backups
./scripts/backup-system.sh --with-vms

# Preview without changes
./scripts/backup-system.sh --dry-run
```

Features:
- Stops configured services before backup
- Runs pre-backup commands (e.g., database dumps)
- Creates timestamped archives
- Prunes old backups according to retention policy
- Compacts repository to reclaim space
- Tracks remote backup success for staleness warnings

### backup-vms.sh

Backs up KVM/libvirt virtual machines.

```bash
# Backup all VMs
./scripts/backup-vms.sh

# Backup specific VM
./scripts/backup-vms.sh /backup/kvm myvm

# Preview without changes
./scripts/backup-vms.sh --dry-run
```

Features:
- Gracefully shuts down running VMs
- Backs up XML configuration
- Backs up all disk images (including backing file chains)
- Backs up NVRAM files for UEFI VMs
- Handles block device disks (NTFS, ext4, etc.)
- Restarts VMs after backup

### backup-database.sh

Generic database backup supporting MySQL/MariaDB and PostgreSQL.

```bash
# Basic usage (uses config)
./scripts/backup-database.sh

# Preview without changes
./scripts/backup-database.sh --dry-run
```

Configuration:
```bash
DB_TYPE="mysql"              # or "postgresql"
DB_HOST="localhost"
DB_USER="backup"
DB_NAME="myapp"
DB_PASSWORD_FILE="/root/.db-password"
DB_BACKUP_DIR="/backup/database"
DB_BACKUP_KEEP=3
```

### restore-system.sh

Interactive script to restore a system from Borg backup to a new disk.

```bash
./scripts/restore-system.sh
```

The script will guide you through:
1. Selecting the Borg repository
2. Selecting the system configuration (or creating one)
3. Selecting the archive to restore
4. Selecting the target disk
5. Creating partitions and LVM
6. Extracting the backup
7. Installing bootloader
8. Rebuilding initramfs

## Automation

### Cron Setup

```bash
# Copy example crontab
sudo cp examples/crontab.example /etc/cron.d/kvm-borg

# Or add to root crontab
sudo crontab -e
```

Example schedule:
```cron
# System backup daily at 3 AM
0 3 * * * /opt/kvm-borg/scripts/backup-system.sh >> /var/log/backup-system.log 2>&1

# VM backup weekly on Sunday at 4 AM
0 4 * * 0 /opt/kvm-borg/scripts/backup-vms.sh >> /var/log/backup-vms.log 2>&1

# Database backup daily at 2:30 AM
30 2 * * * /opt/kvm-borg/scripts/backup-database.sh >> /var/log/backup-database.log 2>&1
```

### Systemd Timers

For more reliable scheduling, use systemd timers instead of cron.

## Security Considerations

### Borg Passphrase

Store the Borg passphrase securely:

```bash
# Option 1: Password file
echo "your-passphrase" > /root/.borg-passphrase
chmod 600 /root/.borg-passphrase

# In backup.conf:
# BORG_PASSPHRASE is intentionally left empty
# Use BORG_PASSCOMMAND in your environment:
export BORG_PASSCOMMAND="cat /root/.borg-passphrase"
```

```bash
# Option 2: pass (password-store)
export BORG_PASSCOMMAND="pass show backup/borg"
```

### Database Password

Never store database passwords in plaintext config:

```bash
# Create password file
echo "db-password" > /root/.db-password
chmod 600 /root/.db-password

# In backup.conf:
DB_PASSWORD_FILE="/root/.db-password"
```

### File Permissions

```bash
chmod 600 /etc/kvm-borg/backup.conf
chmod 700 /etc/kvm-borg
```

## Monitoring

### Staleness Warnings

The system tracks successful remote backups. If a remote backup hasn't succeeded in `REMOTE_STALE_DAYS` (default: 14), a warning is logged.

State files are stored in `/var/lib/backup-state/`.

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Warning (Borg) - backup completed with warnings |
| 2+ | Error |

## Restoring Data

### Restore Entire System

Use the interactive restore script:

```bash
./scripts/restore-system.sh
```

### Restore Single Files

```bash
# List archives
borg list /backup/system

# Extract specific file
cd /tmp
borg extract /backup/system::hostname-2025-01-15-030000 path/to/file

# Extract entire archive
mkdir /tmp/restore
cd /tmp/restore
borg extract /backup/system::hostname-2025-01-15-030000
```

### Restore VM

```bash
# List VM archives
borg list /backup/kvm | grep myvm

# Extract VM
mkdir -p /tmp/vm_restore
cd /tmp/vm_restore
borg extract /backup/kvm::myvm-20250115_030000

# Restore disk files
cp -a virtualmachines/myvm/* /virtualmachines/myvm/

# Restore NVRAM (UEFI VMs)
cp var/lib/libvirt/qemu/nvram/myvm_VARS.fd /var/lib/libvirt/qemu/nvram/
chown qemu:qemu /var/lib/libvirt/qemu/nvram/myvm_VARS.fd

# Define and start VM
virsh define tmp/kvm_backup/myvm/config.xml
virsh start myvm
```

## Troubleshooting

### Lock File Errors

If a backup was interrupted, remove the lock file:

```bash
rm /var/run/backup-system.lock
rm /var/run/backup-vms.lock
```

### Repository Errors

```bash
# Check repository
borg check /backup/system

# Repair repository (use with caution)
borg check --repair /backup/system
```

### Remote Connection Issues

```bash
# Test SSH connection
ssh backup-server 'echo OK'

# Check Borg over SSH
borg info ssh://backup-server/repos/system
```

### VM Shutdown Timeout

If VMs take too long to shut down, the script waits indefinitely. To force:

```bash
virsh destroy myvm  # Force power off (like pulling the plug)
```

## Contributing

Contributions welcome! Please:

1. Test changes with `--dry-run` first
2. Follow existing code style
3. Update documentation as needed

## License

MIT License

Copyright (c) 2025

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

**THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.**
