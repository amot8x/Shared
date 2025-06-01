#!/bin/bash

# === Environment Setup ===

# Set strict error handling
set -euo pipefail

# Update PATH if needed (usually unnecessary unless custom binaries are used)
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# === Configuration Variables ===

# Directory where this script is located
BASE_DIR="$(dirname "$(realpath "$0")")"

# Directory for storing logs
LOG_DIR="$BASE_DIR/logs"

# Log file name: scriptname_YYYY-MM-DD_HH-MM-SS.log
LOG_FILE="$LOG_DIR/$(basename "$0" .sh)_$(date +"%Y-%m-%d_%H-%M-%S").log"

# Borg repository path (e.g., /mnt/usb/borg-repo or user@host:/path/to/repo)
BORG_REPO="REPLACE_WITH_YOUR_BORG_REPO_PATH"

# Path to file containing: export BORG_PASSPHRASE='your_secret'
BORG_PASSPHRASE_FILE="$BASE_DIR/.borg_passphrase"

# Number of days to retain backups
BORG_RETENTION_DAYS=30

# UUID of external USB disk to mount (use `blkid` to find)
USB_DISK_UUID="REPLACE_WITH_YOUR_DISK_UUID"

# Mount point for the USB disk
USB_MOUNT_POINT="/mnt/usb"

# Directories to back up (e.g., Immich backups and library)
IMMICH_BACKUPS_DIR="/mnt/YOUR_PATH/backup"
IMMICH_LIBRARY_DIR="/mnt/YOUR_PATH/library"

# === Logging Setup ===

mkdir -p "$LOG_DIR"

log_message() {
    echo "$(date "+%Y-%m-%d %H:%M:%S") - $1" | tee -a "$LOG_FILE"
}

# === Error Handling ===

trap 'handle_error $LINENO' ERR

handle_error() {
    local line=$1
    log_message "Error on line $line"
    restart_docker_containers  # Implement if needed
    cleanup
    exit 1
}

# === Cleanup Actions ===

cleanup() {
    unmount_usb
}

# === USB Mounting Functions ===

mount_usb() {
    log_message "Mounting USB drive..."
    if mount | grep -q "$USB_MOUNT_POINT"; then
        log_message "USB drive already mounted."
    else
        sudo mount -U "$USB_DISK_UUID" "$USB_MOUNT_POINT" || {
            log_message "Failed to mount USB drive."
            exit 1
        }
    fi
}

unmount_usb() {
    log_message "Unmounting USB drive..."
    sudo umount "$USB_MOUNT_POINT" || true
}

# === Main Script Execution ===

# Load Borg passphrase
if [[ -f "$BORG_PASSPHRASE_FILE" ]]; then
    source "$BORG_PASSPHRASE_FILE"
    if [[ -z "${BORG_PASSPHRASE:-}" ]]; then
        log_message "Error: BORG_PASSPHRASE not set in $BORG_PASSPHRASE_FILE."
        exit 1
    fi
    export BORG_PASSPHRASE
else
    log_message "Error: Passphrase file $BORG_PASSPHRASE_FILE not found."
    exit 1
fi

mount_usb

log_message "Starting backup of Immich directories with Borg..."

borg create --verbose --progress --stats \
    --compression zstd \
    "$BORG_REPO::backup-immich-{now:%Y-%m-%d_%H-%M-%S}" \
    "$IMMICH_BACKUPS_DIR" "$IMMICH_LIBRARY_DIR" >>"$LOG_FILE" 2>&1

log_message "Pruning backups older than $BORG_RETENTION_DAYS days..."

borg prune --verbose --list --stats \
    --keep-within "${BORG_RETENTION_DAYS}d" \
    "$BORG_REPO" >>"$LOG_FILE" 2>&1

log_message "Compacting the Borg repository..."

borg compact --verbose "$BORG_REPO" >>"$LOG_FILE" 2>&1

unmount_usb

log_message "Backup script completed successfully."
