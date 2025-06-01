#!/bin/bash

# === Environment Setup ===
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
BASE_DIR="$(dirname "$(realpath "$0")")"

# === Configurable Variables ===

# Log settings
LOG_DIR="$BASE_DIR/logs"
LOG_FILE="$LOG_DIR/$(basename "$0" .sh)_$(date +"%Y-%m-%d_%H-%M-%S").log"

# Local Borg repository path (must be on a USB drive)
BORG_REPO_LOCAL="/mnt/usb/path/to/backup"  # <--- UPDATE THIS

# Path to Borg passphrase file (must export BORG_PASSPHRASE)
BORG_PASSPHRASE_FILE="$BASE_DIR/.borg_passphrase"

# Telegram settings file (must export TELEGRAM_API_TOKEN and TELEGRAM_CHAT_ID)
TELEGRAM_SETTINGS_FILE="$BASE_DIR/.telegram"

# UUID of the USB disk containing the Borg repo
USB_DISK_UUID="your-usb-uuid"  # <--- UPDATE THIS (use `blkid` to find it)

# Required backup name prefixes to verify
REQUIRED_ITEMS=("backup-immich-")

# === Logging Setup ===
mkdir -p "$LOG_DIR"

log_message() {
    echo "$(date "+%Y-%m-%d %H:%M:%S") - $1" | tee -a "$LOG_FILE"
}

send_telegram_notification() {
    local message="$1"

    if [[ ! -f "$TELEGRAM_SETTINGS_FILE" ]]; then
        log_message "Error: Telegram settings file not found."
        return 1
    fi

    source "$TELEGRAM_SETTINGS_FILE"

    if [[ -z "$TELEGRAM_API_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
        log_message "Error: Telegram API token or chat ID missing."
        return 1
    fi

    log_message "Sending Telegram message..."
    curl -s --max-time 10 -X POST \
        -H "Content-Type: application/json" \
        -d "{\"chat_id\": \"$TELEGRAM_CHAT_ID\", \"text\": \"$message\"}" \
        "https://api.telegram.org/bot$TELEGRAM_API_TOKEN/sendMessage" >>"$LOG_FILE" 2>&1 || {
        log_message "Failed to send Telegram notification."
        return 1
    }
}

# === Load Borg Passphrase ===
if [[ -f "$BORG_PASSPHRASE_FILE" ]]; then
    source "$BORG_PASSPHRASE_FILE"
    if [[ -z "$BORG_PASSPHRASE" ]]; then
        log_message "Error: BORG_PASSPHRASE is empty."
        exit 1
    fi
    export BORG_PASSPHRASE
else
    log_message "Error: Borg passphrase file not found."
    exit 1
fi

# === Mount USB ===
log_message "Mounting USB drive..."
if mount | grep -q "/mnt/usb"; then
    log_message "USB already mounted."
else
    sudo mount -U "$USB_DISK_UUID" /mnt/usb || {
        log_message "Failed to mount USB."
        exit 1
    }
fi

# === Verify Backups ===
REPO="$BORG_REPO_LOCAL"
TODAY=$(date +%Y-%m-%d)

log_message "Verifying backups in: $REPO"
BACKUP_LIST=$(borg list "$REPO" 2>&1)
if [[ $? -ne 0 ]]; then
    log_message "Failed to list backups: $BACKUP_LIST"
    send_telegram_notification "🚨 Backup check failed: Cannot connect to $REPO.\nError:\n$BACKUP_LIST"
    exit 1
fi

# Check for required backup archives
FOUND_ITEMS=()
MISSING_ITEMS=()

for prefix in "${REQUIRED_ITEMS[@]}"; do
    FULL_NAME=$(echo "$BACKUP_LIST" | grep "$prefix$TODAY")
    if [[ -n "$FULL_NAME" ]]; then
        FOUND_ITEMS+=("$FULL_NAME")
    else
        MISSING_ITEMS+=("${prefix}${TODAY}")
    fi
done

if [[ ${#FOUND_ITEMS[@]} -gt 0 ]]; then
    log_message "Found backups for today ($TODAY):"
    for item in "${FOUND_ITEMS[@]}"; do
        log_message "$item"
    done
else
    log_message "No backups found for today."
fi

if [[ ${#MISSING_ITEMS[@]} -eq 0 ]]; then
    log_message "✅ All expected backups are present."
else
    log_message "⚠️ Missing backups: ${MISSING_ITEMS[*]}"
    send_telegram_notification "⚠️ Backup Verification Alert\nDate: $TODAY\nMissing:\n${MISSING_ITEMS[*]}"
fi

# === Unmount USB ===
log_message "Unmounting USB drive..."
sudo umount /mnt/usb || log_message "Warning: Failed to unmount USB."

log_message "Backup verification script completed."
