#!/bin/bash

# clean-fstab.sh - Utility to clean up log contamination from /etc/fstab
# This script removes accidentally leaked log timestamps and command outputs from fstab

# Function for logging messages
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Function for error handling
error_exit() {
    log "ERROR: $1" >&2
    exit 1
}

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
    error_exit "This script must be run as root. Please use sudo."
fi

# Check if fstab exists
if [ ! -f "/etc/fstab" ]; then
    log "No /etc/fstab file found. Nothing to clean."
    exit 0
fi

log "Analyzing /etc/fstab for contamination..."

# Show current fstab content
echo ""
echo "=== Current /etc/fstab content ==="
cat -n /etc/fstab
echo "=================================="
echo ""

# Check for contamination patterns
contamination_found=false

# Check for timestamps
if grep -q '^\[20[0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\]' /etc/fstab 2>/dev/null; then
    log "Found timestamp contamination in /etc/fstab"
    contamination_found=true
fi

# Check for dry run markers
if grep -q '^\[DRY RUN\]' /etc/fstab 2>/dev/null; then
    log "Found DRY RUN contamination in /etc/fstab"
    contamination_found=true
fi

# Check for log messages
if grep -q 'Adding fstab entry for persistence:' /etc/fstab 2>/dev/null; then
    log "Found log message contamination in /etc/fstab"
    contamination_found=true
fi

# Check for command echoes
if grep -q 'echo.*tee.*fstab' /etc/fstab 2>/dev/null; then
    log "Found command echo contamination in /etc/fstab"
    contamination_found=true
fi

if [ "$contamination_found" = false ]; then
    log "No contamination found in /etc/fstab. File appears clean."
    exit 0
fi

echo ""
log "Contamination detected! The following lines will be removed:"
echo ""

# Show what will be removed
echo "=== Lines to be removed ==="
grep '^\[20[0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\]' /etc/fstab 2>/dev/null || true
grep '^\[DRY RUN\]' /etc/fstab 2>/dev/null || true
grep 'Adding fstab entry for persistence:' /etc/fstab 2>/dev/null || true
grep 'echo.*tee.*fstab' /etc/fstab 2>/dev/null || true
echo "============================"
echo ""

# Ask for confirmation
read -p "Do you want to clean these contaminated lines from /etc/fstab? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log "Cleanup cancelled by user."
    exit 0
fi

# Create backup
backup_file="/etc/fstab.backup-$(date +%Y%m%d-%H%M%S)"
log "Creating backup: ${backup_file}"
cp /etc/fstab "${backup_file}" || error_exit "Failed to create backup"

# Count lines before cleanup
lines_before=$(wc -l < /etc/fstab 2>/dev/null || echo "0")

# Perform cleanup
log "Cleaning contaminated entries from /etc/fstab..."

# Remove timestamp lines
sed -i '/^\[20[0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\]/d' /etc/fstab 2>/dev/null

# Remove dry run lines
sed -i '/^\[DRY RUN\]/d' /etc/fstab 2>/dev/null

# Remove log message lines
sed -i '/Adding fstab entry for persistence:/d' /etc/fstab 2>/dev/null

# Remove command echo lines
sed -i '/echo.*tee.*fstab/d' /etc/fstab 2>/dev/null

# Count lines after cleanup
lines_after=$(wc -l < /etc/fstab 2>/dev/null || echo "0")
lines_removed=$((lines_before - lines_after))

log "Cleanup complete! Removed ${lines_removed} contaminated line(s)."
log "Backup saved as: ${backup_file}"

echo ""
echo "=== Cleaned /etc/fstab content ==="
cat -n /etc/fstab
echo "=================================="
echo ""

# Validate fstab syntax
log "Validating /etc/fstab syntax..."
if mount -a --fake 2>/dev/null; then
    log "✅ /etc/fstab syntax is valid"
else
    log "⚠️  WARNING: /etc/fstab may have syntax issues. Please review manually."
    log "   You can restore the backup if needed: sudo cp ${backup_file} /etc/fstab"
fi

log "Cleanup completed successfully!"
log "You may want to test mount operations: sudo mount -a" 