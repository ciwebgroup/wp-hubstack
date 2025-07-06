#!/bin/bash

set -euo pipefail

# This script automates the setup of vsftpd with chroot jail and rbind mounts.
# It allows a system user to access specific directories via mount --rbind
# while being "jailed" to their home directory and the recursively bound mounted directories.

# --- Configuration Variables (Can be overridden by command-line arguments) ---
FTP_USER="ftpuser"                 # The system user for FTP access
HOME_DIR="/home/${FTP_USER}"       # The home directory for the FTP user

# Array of source and destination directories for bind mounts
# Format: "SOURCE_PATH::DESTINATION_PATH_IN_CHROOT"
# Example: BIND_MOUNTS=(" /var/www/mywebsite::public_html " " /opt/shared_docs::docs ")
# Ensure destination paths are relative to HOME_DIR or absolute paths within HOME_DIR
BIND_MOUNTS=(
    "/var/www/mywebsite::public_html"
    "/opt/shared_docs::docs"
)

# vsftpd configuration options
VSFTPD_CONF="/etc/vsftpd.conf"
ALLOW_WRITEABLE_CHROOT="no" # Set to 'yes' if /home/${FTP_USER} must be writable by ${FTP_USER}
                            # (Less secure, 'no' is recommended).
PASV_MIN_PORT="40000"       # Passive mode minimum port
PASV_MAX_PORT="50000"       # Passive mode maximum port

# Firewall configuration
FIREWALL_TYPE="ufw"         # Options: "ufw", "firewalld", "none"

# Dry run flag (default: no)
DRY_RUN="no"                # Set to 'yes' to simulate actions without making changes

# Add mounts only flag (default: no)
ADD_MOUNTS_ONLY="no"        # Set to 'yes' to only add new mounts to existing user

# Generate password flag (default: no)
GENERATE_PASSWORD="no"      # Set to 'yes' to generate and set a temporary password

# Set password flag and value (default: no password set)
SET_PASSWORD="no"           # Set to 'yes' to use a specified password
USER_PASSWORD=""            # The password to set for the user

# Verbose mode flag (default: no)
VERBOSE_MODE="no"           # Set to 'yes' to enable detailed logging

# Check mounts flag (default: no)
CHECK_MOUNTS_ONLY="no"      # Set to 'yes' to only check mount status

# Prep mount bindings flag (default: no)
PREP_MOUNT_BINDINGS="no"    # Set to 'yes' to prepare mount bindings from directory listing

# Process mount bindings flag (default: no)
PROCESS_MOUNT_BINDINGS="no" # Set to 'yes' to process mount bindings directly without creating file

# Prefer TLD directories flag (default: no)
PREFER_TLD_DIRS="no"        # Set to 'yes' to filter only directories that look like domain names

# Keep original owner flag (default: no)
KEEP_ORIGINAL_OWNER="no"    # Set to 'yes' to preserve source directory ownership

# Permission management flags
NORMALIZE_PERMS="no"        # Set to 'yes' to normalize group permissions to match owner
SET_PERMS_FOR_USER="no"     # Set to 'yes' to set specific permissions for user directories
USER_PERMS=""               # The permissions value to set for user directories
SET_PERMS="no"              # Set to 'yes' to set permissions for both source and user directories
ALL_PERMS=""                # The permissions value to set for both source and user directories

# --- Script Functions ---

# Function to display usage information
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Automates vsftpd setup with chroot and rbind mounts."
    echo ""
    echo "Options:"
    echo "  -u, --user <username>          Set the FTP system username (default: ${FTP_USER})"
    echo "  -b, --bind-mounts <mounts>     Set bind mounts in one of two formats:"
    echo "                                 1. Space-separated: 'src1::dest1 src2::dest2'"
    echo "                                 2. File path: path to text file with one mount per line"
    echo "                                 File format: each line should be 'source::destination'"
    echo "                                 (Comments with # or // are supported in files)"
    echo "  -w, --writable-chroot          Enable 'allow_writeable_chroot=YES' (less secure)"
    echo "  -f, --firewall <type>          Set firewall type (ufw, firewalld, none, default: ${FIREWALL_TYPE})"
    echo "  -p, --pasv-ports <min:max>     Set passive port range (default: ${PASV_MIN_PORT}:${PASV_MAX_PORT})"
    echo "  --add-mounts-only              Only add new mounts to existing user (skip full setup)"
    echo "  --generate-password            Generate and set a temporary password for the user"
    echo "  --set-password <password>      Set a specific password for the user"
    echo "  --verbose                      Enable verbose logging and detailed output"
    echo "  --check-mounts                 Check and report status of existing mounts"
    echo "  --prep-mount-bindings [dir]    Process directories and create mount bindings file"
    echo "  --process-mount-bindings [dir] Process directories and set up mounts directly (no file)"
    echo "  --prefer-tld-dirs              Filter only directories that look like domain names with TLDs"
    echo "  --keep-original-owner          Preserve source directory ownership, add FTP user to group"
    echo "  --normalize-perms              Normalize group permissions to match owner permissions"
    echo "  --set-perms-for-user <perms>   Set specific permissions for user directories (e.g., 755)"
    echo "  --set-perms <perms>            Set permissions for both source and user directories"
    echo "  --dry-run                      Simulate the execution without making any changes"
    echo "  -h, --help                     Display this help message"
    echo ""
    echo "Examples:"
    echo "  # Full setup with space-separated mounts:"
    echo "  sudo $0 -u myftpuser -b '/var/web::webroot /data::shared' -f ufw --dry-run"
    echo ""
    echo "  # Full setup using bind mounts file:"
    echo "  sudo $0 -u myftpuser -b /path/to/mounts.txt --generate-password"
    echo ""
    echo "  # Add new mounts from file to existing user:"
    echo "  sudo $0 -u myftpuser -b /path/to/additional-mounts.txt --add-mounts-only"
    echo ""
    echo "  # Check mount status for existing user:"
    echo "  sudo $0 -u myftpuser -b /path/to/mounts.txt --check-mounts"
    echo ""
    echo "  # Prepare mount bindings from directory listing:"
    echo "  sudo $0 --prep-mount-bindings /var/www"
    echo "  sudo $0 --prep-mount-bindings  # (uses current directory)"
    echo "  sudo $0 --prep-mount-bindings /var/www --prefer-tld-dirs  # (filter domain-like dirs)"
    echo ""
    echo "  # Process mount bindings directly without creating file:"
    echo "  sudo $0 -u myftpuser --process-mount-bindings /var/www"
    echo "  sudo $0 -u myftpuser --process-mount-bindings /var/www --prefer-tld-dirs"
    echo "  sudo $0 -u myftpuser --process-mount-bindings /var/www --set-password 'SecurePass123'"
    echo ""
    echo "  # Verbose setup with detailed logging:"
    echo "  sudo $0 -u myftpuser -b /path/to/mounts.txt --verbose --generate-password"
    echo ""
    echo "  # Set a specific password for the user:"
    echo "  sudo $0 -u myftpuser -b /path/to/mounts.txt --set-password 'MySecurePassword123'"
    echo ""
    echo "  # Preserve original ownership and add FTP user to existing groups:"
    echo "  sudo $0 -u myftpuser -b /path/to/mounts.txt --keep-original-owner"
    echo ""
    echo "  # Set specific permissions for user directories:"
    echo "  sudo $0 -u myftpuser -b /path/to/mounts.txt --set-perms-for-user 755"
    echo ""
    echo "  # Set permissions for both source and user directories:"
    echo "  sudo $0 -u myftpuser -b /path/to/mounts.txt --set-perms 775"
    echo ""
    echo "  # Normalize permissions with original owner preservation:"
    echo "  sudo $0 -u myftpuser -b /path/to/mounts.txt --keep-original-owner --normalize-perms"
    echo ""
    echo "Bind mounts file format example (/path/to/mounts.txt):"
    echo "  # Web directories"
    echo "  /var/www/site1::site1"
    echo "  /var/www/site2::site2"
    echo "  // Shared resources"
    echo "  /opt/shared::shared"
    echo "  /data/uploads::uploads"
    echo ""
    echo "Notes:"
    echo "  --keep-original-owner preserves existing directory ownership and adds the FTP user"
    echo "  to the source directory's group instead of changing ownership. This allows multiple"
    echo "  FTP users to share access to the same directories while maintaining original permissions."
    echo "  Group permissions are normalized to match owner permissions when necessary."
    echo ""
    echo "  --prep-mount-bindings scans a directory for subdirectories and creates a mount"
    echo "  bindings file. Each subdirectory is formatted as 'absolute_path::sites/dirname'."
    echo "  If no directory is specified, the current working directory is used. The output"
    echo "  file is timestamped and can be used directly with the --bind-mounts option."
    echo ""
    echo "  --process-mount-bindings combines directory scanning with full FTP setup in one"
    echo "  command. It scans the specified directory for subdirectories and automatically"
    echo "  sets up bind mounts without creating an intermediate file. This streamlines the"
    echo "  workflow by eliminating the two-step process of prep + setup."
    echo ""
    echo "  --prefer-tld-dirs filters directories to only include those that look like domain"
    echo "  names with recognized TLDs (traditional, country code, and modern generic TLDs)."
    echo "  This is useful for web hosting environments where directories are named after domains."
    echo "  Examples: example.com, mysite.org, business.tech, company.co.uk would be included."
    echo ""
    echo "  Password options: Use --generate-password for a secure random password, or"
    echo "  --set-password to specify your own. These options are mutually exclusive."
    echo "  If neither is used, you must set a password manually with 'sudo passwd username'."
    echo "  For security, consider using strong passwords with mixed case, numbers, and symbols."
    echo ""
    echo "  Permission options:"
    echo "  --normalize-perms only applies when --keep-original-owner is used. It ensures"
    echo "  group permissions match owner permissions for shared access."
    echo "  --set-perms-for-user sets permissions only on user directories (home, uploads, bind destinations)."
    echo "  --set-perms sets permissions on both source directories and user directories."
    echo "  These permission flags are mutually exclusive with automatic permission handling."
    exit 1
}

# Function for logging messages (includes DRY RUN prefix if enabled)
log() {
    local prefix=""
    if [ "${DRY_RUN}" == "yes" ]; then
        prefix="[DRY RUN] "
    fi
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ${prefix}$1"
}

# Function for verbose logging (only shown when verbose mode is enabled)
verbose_log() {
    if [ "${VERBOSE_MODE}" == "yes" ]; then
        local prefix="[VERBOSE] "
        if [ "${DRY_RUN}" == "yes" ]; then
            prefix="[DRY RUN VERBOSE] "
        fi
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] ${prefix}$1"
    fi
}

# Function for error handling and exiting (only exits for real runs)
error_exit() {
    log "ERROR: $1" >&2 # Use log function to print with dry-run prefix
    if [ "${DRY_RUN}" == "no" ]; then
        exit 1 # Only exit for real runs
    else
        log "Dry run indicates this would have been a fatal error."
    fi
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to execute a command or log it during dry run
execute_or_log() {
    local cmd_description="$1"
    shift
    local cmd_to_execute=("$@") # Capture all remaining arguments as the command

    log "${cmd_description}: ${cmd_to_execute[*]}"
    if [ "${DRY_RUN}" == "no" ]; then
        "${cmd_to_execute[@]}"
        return $? # Return the exit code of the executed command
    fi
    return 0 # Always succeed in dry run
}

# Function to generate a secure temporary password
generate_temp_password() {
    # Generate a 16-character password with letters, numbers, and safe symbols
    # Using /dev/urandom for cryptographically secure randomness
    if command_exists openssl; then
        # Use openssl for better randomness (most common)
        openssl rand -base64 32 | tr -d "=+/" | cut -c1-16
    elif [ -r /dev/urandom ]; then
        # Fallback to /dev/urandom with tr
        tr -dc 'A-Za-z0-9!@#$%^&*' < /dev/urandom | head -c 16
    else
        # Last resort - use $RANDOM (less secure but universally available)
        echo "$(date +%s)${RANDOM}${RANDOM}" | sha256sum | head -c 16
    fi
}

# Function to set password for user
set_user_password() {
    local username="$1"
    local password="$2"
    
    if [ "${DRY_RUN}" == "no" ]; then
        # Use chpasswd to set password non-interactively
        echo "${username}:${password}" | sudo chpasswd
        return $?
    else
        log "DRY RUN: Would set password for user ${username}"
        return 0
    fi
}


# Function to safely add an entry to /etc/fstab without logging contamination
add_fstab_entry() {
    local fstab_entry="$1"
    local description="$2"
    
    if [ "${DRY_RUN}" == "yes" ]; then
        log "DRY RUN: Would add fstab entry: ${fstab_entry}"
        return 0
    fi
    
    # Check if entry already exists
    if grep -Fxq "${fstab_entry}" /etc/fstab 2>/dev/null; then
        log "Fstab entry already exists: ${fstab_entry}"
        return 0
    fi
    
    # Add the fstab entry using a completely isolated write operation
    (
        # Redirect all output to prevent any accidental logging contamination
        exec 1>/dev/null 2>/dev/null
        # Write the fstab entry using printf to avoid shell interpretation
        printf '%s\n' "${fstab_entry}" | sudo tee -a /etc/fstab >/dev/null 2>&1
    )
    
    # Verify the entry was added successfully
    if grep -Fxq "${fstab_entry}" /etc/fstab 2>/dev/null; then
        log "Added fstab entry: ${fstab_entry}"
    else
        error_exit "Failed to add fstab entry: ${fstab_entry}"
    fi
}

# Function to remove duplicate fstab entries
remove_duplicate_fstab_entries() {
    if [ "${DRY_RUN}" == "yes" ]; then
        log "DRY RUN: Would remove duplicate fstab entries"
        return 0
    fi
    
    if [ ! -f "/etc/fstab" ]; then
        return 0  # File doesn't exist, nothing to clean
    fi
    
    # Create a temporary file to store unique entries
    local temp_fstab=$(mktemp)
    
    # Remove duplicates while preserving order (keeps first occurrence)
    awk '!seen[$0]++' /etc/fstab > "${temp_fstab}"
    
    # Count duplicates removed
    local original_lines=$(wc -l < /etc/fstab 2>/dev/null || echo "0")
    local unique_lines=$(wc -l < "${temp_fstab}" 2>/dev/null || echo "0")
    local duplicates_removed=$((original_lines - unique_lines))
    
    if [ ${duplicates_removed} -gt 0 ]; then
        # Backup original fstab
        sudo cp /etc/fstab /etc/fstab.backup-duplicates-$(date +%Y%m%d-%H%M%S) 2>/dev/null || true
        
        # Replace with deduplicated version
        sudo cp "${temp_fstab}" /etc/fstab
        log "Removed ${duplicates_removed} duplicate entries from /etc/fstab (backup created)"
    fi
    
    # Clean up temp file
    rm -f "${temp_fstab}"
}

# Function to clean up any accidentally leaked log timestamps from /etc/fstab
clean_fstab_timestamps() {
    if [ "${DRY_RUN}" == "yes" ]; then
        log "DRY RUN: Would clean any timestamp entries from /etc/fstab"
        return 0
    fi
    
    if [ ! -f "/etc/fstab" ]; then
        return 0  # File doesn't exist, nothing to clean
    fi
    
    # Backup fstab before cleaning
    sudo cp /etc/fstab /etc/fstab.backup-$(date +%Y%m%d-%H%M%S) 2>/dev/null || true
    
    # Remove any lines that look like timestamps or log entries
    local lines_removed=0
    
    # Count lines before cleanup
    local lines_before=$(wc -l < /etc/fstab 2>/dev/null || echo "0")
    
    # Remove timestamp lines, dry run lines, and log contamination
    sudo sed -i '/^\[20[0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\]/d' /etc/fstab 2>/dev/null
    sudo sed -i '/^\[DRY RUN\]/d' /etc/fstab 2>/dev/null
    sudo sed -i '/Adding fstab entry for persistence:/d' /etc/fstab 2>/dev/null
    sudo sed -i '/echo.*tee.*fstab/d' /etc/fstab 2>/dev/null
    
    # Count lines after cleanup
    local lines_after=$(wc -l < /etc/fstab 2>/dev/null || echo "0")
    lines_removed=$((lines_before - lines_after))
    
    if [ ${lines_removed} -gt 0 ]; then
        log "Cleaned ${lines_removed} contaminated entries from /etc/fstab (backup created)"
    fi
}

# Function to validate mount configuration
validate_mount_config() {
    local mount_pair="$1"
    local source_path="${mount_pair%%::*}"
    local dest_path="${mount_pair##*::}"
    
    # Validate source path
    if [[ ! "$source_path" =~ ^/ ]]; then
        log "ERROR: Source path must be absolute: ${source_path}"
        return 1
    fi
    
    # Validate destination path (should be relative)
    if [[ "$dest_path" =~ ^/ ]]; then
        log "WARNING: Destination path should be relative to chroot: ${dest_path}"
        dest_path="${dest_path#/}"
        log "Converting to relative path: ${dest_path}"
    fi
    
    # Check if source path exists or can be created
    if [ ! -d "${source_path}" ]; then
        if [ "${DRY_RUN}" == "no" ]; then
            log "WARNING: Source directory does not exist and will be created: ${source_path}"
        else
            log "DRY RUN: Source directory would be created: ${source_path}"
        fi
    fi
    
    # Validate destination path doesn't contain dangerous characters
    if [[ "$dest_path" =~ \.\. ]] || [[ "$dest_path" =~ ^/ ]]; then
        log "ERROR: Destination path contains dangerous characters: ${dest_path}"
        return 1
    fi
    
    return 0
}

# Function to handle source directory permissions (either change ownership or add to group)
setup_source_directory_permissions() {
    local source_path="$1"
    local ftp_user="$2"
    
    if [ ! -d "${source_path}" ]; then
        verbose_log "Source directory does not exist, creating: ${source_path}"
        execute_or_log "Creating source directory ${source_path}" sudo mkdir -p "${source_path}" || error_exit "Failed to create source directory ${source_path}."
    fi
    
    # Handle --set-perms flag (affects both source and user directories)
    if [ "${SET_PERMS}" == "yes" ]; then
        verbose_log "Setting permissions to ${ALL_PERMS} for source directory: ${source_path}"
        execute_or_log "Setting permissions of source directory ${source_path} to ${ALL_PERMS}" sudo chmod -R "${ALL_PERMS}" "${source_path}" || log "Warning: Failed to set permissions of ${source_path}. Check manually."
        
        # For --set-perms, we still need to handle ownership
        if [ "${KEEP_ORIGINAL_OWNER}" == "yes" ]; then
            # Get current owner and group of the source directory
            local current_owner=$(stat -c '%U' "${source_path}" 2>/dev/null || echo "unknown")
            local current_group=$(stat -c '%G' "${source_path}" 2>/dev/null || echo "unknown")
            
            verbose_log "Source directory current ownership: ${current_owner}:${current_group}"
            
            if [ "${current_owner}" == "unknown" ] || [ "${current_group}" == "unknown" ]; then
                log "WARNING: Could not determine current ownership of ${source_path}. Falling back to ownership change."
                execute_or_log "Setting ownership of source directory ${source_path}" sudo chown -R "${ftp_user}:${ftp_user}" "${source_path}" || log "Warning: Failed to set ownership of ${source_path}. Check manually."
            else
                # Check if the FTP user is already in the group
                if groups "${ftp_user}" 2>/dev/null | grep -q "\b${current_group}\b"; then
                    verbose_log "User ${ftp_user} is already in group ${current_group}"
                else
                    log "Adding user ${ftp_user} to group ${current_group} for shared access"
                    execute_or_log "Adding user ${ftp_user} to group ${current_group}" sudo usermod -a -G "${current_group}" "${ftp_user}" || log "Warning: Failed to add ${ftp_user} to group ${current_group}. Check manually."
                fi
                log "Preserved ownership ${current_owner}:${current_group} for ${source_path}, added ${ftp_user} to group"
            fi
        else
            # Change ownership to FTP user
            execute_or_log "Setting ownership of source directory ${source_path}" sudo chown -R "${ftp_user}:${ftp_user}" "${source_path}" || log "Warning: Failed to set ownership of ${source_path}. Check manually."
            log "Changed ownership to ${ftp_user}:${ftp_user} for ${source_path}"
        fi
        
        log "Set permissions to ${ALL_PERMS} for ${source_path}"
        return
    fi
    
    if [ "${KEEP_ORIGINAL_OWNER}" == "yes" ]; then
        # Get current owner and group of the source directory
        local current_owner=$(stat -c '%U' "${source_path}" 2>/dev/null || echo "unknown")
        local current_group=$(stat -c '%G' "${source_path}" 2>/dev/null || echo "unknown")
        local current_perms=$(stat -c '%a' "${source_path}" 2>/dev/null || echo "755")
        
        verbose_log "Source directory current ownership: ${current_owner}:${current_group} (${current_perms})"
        
        if [ "${current_owner}" == "unknown" ] || [ "${current_group}" == "unknown" ]; then
            log "WARNING: Could not determine current ownership of ${source_path}. Falling back to ownership change."
            execute_or_log "Setting ownership of source directory ${source_path}" sudo chown -R "${ftp_user}:${ftp_user}" "${source_path}" || log "Warning: Failed to set ownership of ${source_path}. Check manually."
            execute_or_log "Setting permissions of source directory ${source_path}" sudo chmod -R 775 "${source_path}" || log "Warning: Failed to set permissions of ${source_path}. Check manually."
            return
        fi
        
        # Check if the FTP user is already in the group
        if groups "${ftp_user}" 2>/dev/null | grep -q "\b${current_group}\b"; then
            verbose_log "User ${ftp_user} is already in group ${current_group}"
        else
            log "Adding user ${ftp_user} to group ${current_group} for shared access"
            execute_or_log "Adding user ${ftp_user} to group ${current_group}" sudo usermod -a -G "${current_group}" "${ftp_user}" || log "Warning: Failed to add ${ftp_user} to group ${current_group}. Check manually."
        fi
        
        # Normalize permissions if --normalize-perms flag is set
        if [ "${NORMALIZE_PERMS}" == "yes" ]; then
            # Convert current permissions to ensure group has read/write/execute as needed
            local owner_perms=$((current_perms / 100))
            local group_perms=$(((current_perms / 10) % 10))
            local other_perms=$((current_perms % 10))
            
            # Ensure group has at least the same permissions as owner (but not more)
            if [ ${group_perms} -lt ${owner_perms} ]; then
                local new_perms="${owner_perms}${owner_perms}${other_perms}"
                log "Normalizing permissions from ${current_perms} to ${new_perms} for group access"
                execute_or_log "Normalizing permissions of source directory ${source_path}" sudo chmod -R "${new_perms}" "${source_path}" || log "Warning: Failed to normalize permissions of ${source_path}. Check manually."
            else
                verbose_log "Permissions already adequate for group access: ${current_perms}"
            fi
        else
            verbose_log "Permission normalization skipped (--normalize-perms not specified)"
        fi
        
        log "Preserved ownership ${current_owner}:${current_group} for ${source_path}, added ${ftp_user} to group"
        
    else
        # Original behavior - change ownership to FTP user
        verbose_log "Changing ownership of source directory to ${ftp_user}:${ftp_user}"
        execute_or_log "Setting ownership of source directory ${source_path}" sudo chown -R "${ftp_user}:${ftp_user}" "${source_path}" || log "Warning: Failed to set ownership of ${source_path}. Check manually."
        execute_or_log "Setting permissions of source directory ${source_path}" sudo chmod -R 775 "${source_path}" || log "Warning: Failed to set permissions of ${source_path}. Check manually."
        log "Changed ownership to ${ftp_user}:${ftp_user} for ${source_path}"
    fi
}

# Function to check if a directory name looks like a domain name with TLD
is_domain_like() {
    local dirname="$1"
    
    # Convert to lowercase for case-insensitive matching
    local lowercase_dirname=$(echo "$dirname" | tr '[:upper:]' '[:lower:]')
    
    # Comprehensive list of TLDs (traditional, country code, and modern generic TLDs)
    local tlds=(
        # Traditional TLDs
        "com" "org" "net" "edu" "gov" "mil" "int" "info" "biz" "name" "pro" "aero" "coop" "museum"
        
        # Country code TLDs (major ones)
        "us" "uk" "ca" "au" "de" "fr" "it" "jp" "cn" "ru" "br" "mx" "in" "es" "nl" "ch" "se" "no" "dk" "fi"
        "be" "at" "pl" "ie" "pt" "gr" "cz" "hu" "sk" "si" "bg" "ro" "hr" "rs" "ba" "mk" "al" "me" "md"
        "ua" "by" "lt" "lv" "ee" "is" "mt" "cy" "lu" "li" "ad" "mc" "sm" "va" "gi" "im" "je" "gg"
        "za" "eg" "ma" "ng" "ke" "gh" "tz" "ug" "rw" "mw" "zm" "zw" "bw" "na" "sz" "ls" "mg" "mu"
        "kr" "tw" "hk" "sg" "my" "th" "ph" "id" "vn" "bd" "pk" "lk" "np" "mm" "kh" "la" "bn" "mv"
        "ar" "cl" "pe" "co" "ve" "uy" "py" "bo" "ec" "gf" "sr" "gy" "fk" "cr" "gt" "hn" "ni" "pa"
        "cu" "do" "ht" "jm" "tt" "bb" "gd" "lc" "vc" "ag" "dm" "kn" "ms" "ai" "vg" "vi" "pr" "bz"
        "nz" "fj" "pg" "sb" "vu" "nc" "pf" "ws" "to" "tv" "ki" "nr" "pw" "fm" "mh" "mp" "gu" "as"
        
        # Modern generic TLDs
        "app" "dev" "io" "ai" "tech" "blog" "shop" "store" "online" "site" "website" "web" "digital"
        "cloud" "host" "domains" "email" "click" "link" "download" "zip" "mov" "new" "art" "design"
        "studio" "agency" "company" "business" "services" "solutions" "consulting" "management" "group"
        "team" "work" "jobs" "career" "professional" "expert" "guru" "ninja" "rocks" "cool" "fun"
        "game" "games" "play" "sport" "fitness" "health" "medical" "dental" "clinic" "hospital"
        "law" "legal" "attorney" "lawyer" "accountant" "tax" "finance" "bank" "money" "insurance"
        "loan" "credit" "investment" "trading" "forex" "crypto" "bitcoin" "blockchain" "nft"
        "education" "academy" "school" "college" "university" "training" "course" "learn" "study"
        "news" "media" "tv" "radio" "music" "video" "photo" "gallery" "movie" "film" "theater"
        "book" "library" "author" "writer" "publisher" "magazine" "journal" "review" "blog"
        "food" "restaurant" "cafe" "bar" "pub" "wine" "beer" "pizza" "kitchen" "recipe" "cooking"
        "travel" "hotel" "flights" "vacation" "holiday" "tour" "cruise" "adventure" "camping"
        "fashion" "clothing" "shoes" "jewelry" "beauty" "cosmetics" "salon" "spa" "wellness"
        "auto" "car" "cars" "truck" "motorcycle" "bike" "parts" "repair" "garage" "dealer"
        "house" "home" "real" "estate" "property" "apartment" "rent" "buy" "sell" "mortgage"
        "garden" "flowers" "plants" "landscaping" "construction" "tools" "equipment" "supplies"
        "pet" "pets" "dog" "cat" "animal" "vet" "veterinary" "grooming" "breeding" "training"
        "baby" "kids" "children" "toys" "games" "family" "mom" "dad" "parenting" "pregnancy"
        "senior" "retirement" "pension" "insurance" "life" "death" "funeral" "memorial"
        "charity" "foundation" "nonprofit" "volunteer" "community" "social" "environment"
        "green" "eco" "solar" "energy" "power" "electric" "gas" "oil" "mining" "metals"
        "science" "research" "lab" "laboratory" "chemistry" "physics" "biology" "medicine"
        "technology" "software" "hardware" "computer" "internet" "wireless" "mobile" "phone"
        "security" "safety" "protection" "guard" "alarm" "camera" "surveillance" "monitoring"
        "cleaning" "maintenance" "repair" "service" "support" "help" "customer" "client"
        "marketing" "advertising" "promotion" "sales" "commerce" "trade" "export" "import"
        "logistics" "shipping" "delivery" "transport" "freight" "cargo" "warehouse" "storage"
        "manufacturing" "factory" "production" "industrial" "machinery" "equipment" "tools"
        "agriculture" "farming" "livestock" "crops" "seeds" "fertilizer" "organic" "natural"
        "fishing" "marine" "ocean" "sea" "water" "river" "lake" "beach" "island" "coast"
        "mountain" "ski" "snow" "winter" "summer" "spring" "fall" "weather" "climate"
        "city" "town" "village" "county" "state" "country" "region" "local" "global" "international"
        "xxx" "adult" "sex" "dating" "singles" "romance" "love" "wedding" "marriage" "divorce"
    )
    
    # Check if dirname ends with any of the TLDs
    for tld in "${tlds[@]}"; do
        # Check if dirname ends with .tld (with dot)
        if [[ "$lowercase_dirname" =~ \.$tld$ ]]; then
            verbose_log "Directory '$dirname' matches TLD pattern (.$tld)"
            return 0
        fi
        # Also check if dirname ends with just the tld (without dot)
        if [[ "$lowercase_dirname" =~ ^.*[^a-zA-Z0-9]$tld$ ]] || [[ "$lowercase_dirname" == *"$tld" ]]; then
            # Make sure it's not just a substring match - require word boundary
            if [[ "$lowercase_dirname" =~ (^|[^a-zA-Z0-9])$tld$ ]]; then
                verbose_log "Directory '$dirname' matches TLD pattern ($tld)"
                return 0
            fi
        fi
    done
    
    # Additional check for domain-like patterns (at least one dot and valid characters)
    if [[ "$lowercase_dirname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]]; then
        verbose_log "Directory '$dirname' matches generic domain pattern"
        return 0
    fi
    
    verbose_log "Directory '$dirname' does not match any domain pattern"
    return 1
}

# Function to process mount bindings directly without creating file
process_mount_bindings() {
    local target_dir="$1"
    local ftp_user="$2"
    local home_dir="$3"
    
    log "Processing mount bindings directly from directory: ${target_dir}"
    log "FTP user: ${ftp_user}"
    log "Home directory: ${home_dir}"
    
    # Validate target directory
    if [ ! -d "${target_dir}" ]; then
        error_exit "Target directory does not exist: ${target_dir}"
    fi
    
    # Convert target directory to absolute path
    local abs_target_dir
    if command_exists realpath; then
        abs_target_dir=$(realpath "${target_dir}")
    else
        # Fallback for systems without realpath
        abs_target_dir=$(cd "${target_dir}" && pwd)
    fi
    
    verbose_log "Target directory (absolute): ${abs_target_dir}"
    
    # Tracking variables
    local binding_count=0
    local processed_mounts=()
    
    log "Scanning directories in: ${abs_target_dir}"
    
    # Log TLD filtering status
    if [ "${PREFER_TLD_DIRS}" == "yes" ]; then
        log "TLD filtering is enabled - only domain-like directories will be processed"
    fi
    
    # Note: For dry run, we still need to scan directories to show what would be processed
    # We just won't perform the actual mount operations later
    
    # List directories and process them using find
    while IFS= read -r -d '' dir; do
        # Get absolute path of the directory
        local abs_dir
        if command_exists realpath; then
            abs_dir=$(realpath "${dir}")
        else
            abs_dir=$(cd "${dir}" && pwd)
        fi
        
        # Get basename for the destination
        local basename=$(basename "${abs_dir}")
        
        # Skip if directory name is empty or contains problematic characters
        if [[ -z "${basename}" ]] || [[ "${basename}" =~ [[:space:]] ]] || [[ "${basename}" =~ \.\. ]]; then
            if [ "${DRY_RUN}" == "yes" ]; then
                log "DRY RUN: Would skip directory with problematic name: ${basename}"
            else
                log "Warning: Skipping directory with problematic name: ${basename}"
            fi
            continue
        fi
        
        # Apply TLD filtering if --prefer-tld-dirs is enabled
        if [ "${PREFER_TLD_DIRS}" == "yes" ]; then
            if ! is_domain_like "${basename}"; then
                if [ "${DRY_RUN}" == "yes" ]; then
                    log "DRY RUN: Would skip directory '${basename}' (does not match domain pattern)"
                else
                    verbose_log "Skipping directory '${basename}' (does not match domain pattern)"
                fi
                continue
            fi
        fi
        
        # Format as source::sites/destination
        local mount_binding="${abs_dir}::sites/${basename}"
        processed_mounts+=("${mount_binding}")
        binding_count=$((binding_count + 1))
        
        if [ "${DRY_RUN}" == "yes" ]; then
            log "DRY RUN: Would process directory '${basename}' -> '${mount_binding}'"
        else
            verbose_log "Found binding: ${mount_binding}"
        fi
        
    done < <(find "${abs_target_dir}" -maxdepth 1 -type d ! -path "${abs_target_dir}" -print0 2>/dev/null)
    
    # If no directories found, try a different approach
    if [ ${binding_count} -eq 0 ]; then
        log "No subdirectories found using find. Trying ls approach..."
        
        # Use ls -d with glob pattern
        for dir in "${abs_target_dir}"/*/; do
            # Check if glob pattern matched any directories
            if [ -d "${dir}" ]; then
                local abs_dir
                if command_exists realpath; then
                    abs_dir=$(realpath "${dir}")
                else
                    abs_dir=$(cd "${dir}" && pwd)
                fi
                
                local basename=$(basename "${abs_dir}")
                
                # Skip if directory name contains problematic characters
                if [[ -z "${basename}" ]] || [[ "${basename}" =~ [[:space:]] ]] || [[ "${basename}" =~ \.\. ]]; then
                    if [ "${DRY_RUN}" == "yes" ]; then
                        log "DRY RUN: Would skip directory with problematic name: ${basename}"
                    else
                        log "Warning: Skipping directory with problematic name: ${basename}"
                    fi
                    continue
                fi
                
                # Apply TLD filtering if --prefer-tld-dirs is enabled
                if [ "${PREFER_TLD_DIRS}" == "yes" ]; then
                    if ! is_domain_like "${basename}"; then
                        if [ "${DRY_RUN}" == "yes" ]; then
                            log "DRY RUN: Would skip directory '${basename}' (does not match domain pattern)"
                        else
                            verbose_log "Skipping directory '${basename}' (does not match domain pattern)"
                        fi
                        continue
                    fi
                fi
                
                local mount_binding="${abs_dir}::sites/${basename}"
                processed_mounts+=("${mount_binding}")
                binding_count=$((binding_count + 1))
                
                if [ "${DRY_RUN}" == "yes" ]; then
                    log "DRY RUN: Would process directory '${basename}' -> '${mount_binding}'"
                else
                    verbose_log "Found binding: ${mount_binding}"
                fi
            fi
        done
    fi
    
    if [ ${binding_count} -eq 0 ]; then
        log "Warning: No directories found in ${abs_target_dir}"
        return 1
    fi
    
    if [ "${DRY_RUN}" == "yes" ]; then
        log "DRY RUN: Found ${binding_count} directories that would be processed as mount bindings"
    else
        log "Found ${binding_count} directories to process as mount bindings"
    fi
    
    # Set the global BIND_MOUNTS array to our processed mounts
    BIND_MOUNTS=("${processed_mounts[@]}")
    
    # Display the processed mounts if verbose mode is enabled OR if dry run mode is enabled
    if [ "${VERBOSE_MODE}" == "yes" ] || [ "${DRY_RUN}" == "yes" ]; then
        if [ "${DRY_RUN}" == "yes" ]; then
            log "DRY RUN: Mount bindings that would be processed:"
        else
            log "Processed mount bindings:"
        fi
        for mount_binding in "${BIND_MOUNTS[@]}"; do
            log "  ${mount_binding}"
        done
    fi
    
    if [ "${DRY_RUN}" == "yes" ]; then
        log "DRY RUN: Would process ${#BIND_MOUNTS[@]} mount binding(s) for direct setup"
    else
        log "Successfully processed ${#BIND_MOUNTS[@]} mount binding(s) for direct setup"
    fi
    return 0
}

# Function to prepare mount bindings from directory listing
prep_mount_bindings() {
    local target_dir="$1"
    local output_file="${2:-mount_bindings.txt}"
    
    log "Preparing mount bindings from directory: ${target_dir}"
    log "Output file: ${output_file}"
    
    # Validate target directory
    if [ ! -d "${target_dir}" ]; then
        error_exit "Target directory does not exist: ${target_dir}"
    fi
    
    # Convert target directory to absolute path
    local abs_target_dir
    if command_exists realpath; then
        abs_target_dir=$(realpath "${target_dir}")
    else
        # Fallback for systems without realpath
        abs_target_dir=$(cd "${target_dir}" && pwd)
    fi
    
    verbose_log "Target directory (absolute): ${abs_target_dir}"
    
    # Create temporary file for processing
    local temp_file=$(mktemp)
    local binding_count=0
    
    log "Scanning directories in: ${abs_target_dir}"
    
    # Log TLD filtering status
    if [ "${PREFER_TLD_DIRS}" == "yes" ]; then
        log "TLD filtering is enabled - only domain-like directories will be included"
    fi
    
    # Use ls -d to list directories, then process each one
    if [ "${DRY_RUN}" == "yes" ]; then
        log "DRY RUN: Would execute: ls -d ${abs_target_dir}/*/ 2>/dev/null"
        log "DRY RUN: Would create mount bindings file: ${output_file}"
        if [ "${PREFER_TLD_DIRS}" == "yes" ]; then
            log "DRY RUN: Would apply TLD filtering to found directories"
        fi
        return 0
    fi
    
    # List directories and process them
    while IFS= read -r -d '' dir; do
        # Get absolute path of the directory
        local abs_dir
        if command_exists realpath; then
            abs_dir=$(realpath "${dir}")
        else
            abs_dir=$(cd "${dir}" && pwd)
        fi
        
        # Get basename for the destination
        local basename=$(basename "${abs_dir}")
        
        # Skip if directory name is empty or contains problematic characters
        if [[ -z "${basename}" ]] || [[ "${basename}" =~ [[:space:]] ]] || [[ "${basename}" =~ \.\. ]]; then
            log "Warning: Skipping directory with problematic name: ${basename}"
            continue
        fi
        
        # Apply TLD filtering if --prefer-tld-dirs is enabled
        if [ "${PREFER_TLD_DIRS}" == "yes" ]; then
            if ! is_domain_like "${basename}"; then
                verbose_log "Skipping directory '${basename}' (does not match domain pattern)"
                continue
            fi
        fi
        
        # Format as source::sites/destination
        local mount_binding="${abs_dir}::sites/${basename}"
        
        # Add to temp file
        echo "${mount_binding}" >> "${temp_file}"
        binding_count=$((binding_count + 1))
        
        verbose_log "Added binding: ${mount_binding}"
        
    done < <(find "${abs_target_dir}" -maxdepth 1 -type d ! -path "${abs_target_dir}" -print0 2>/dev/null)
    
    # If no directories found, try a different approach
    if [ ${binding_count} -eq 0 ]; then
        log "No subdirectories found using find. Trying ls approach..."
        
        # Use ls -d with glob pattern
        for dir in "${abs_target_dir}"/*/; do
            # Check if glob pattern matched any directories
            if [ -d "${dir}" ]; then
                local abs_dir
                if command_exists realpath; then
                    abs_dir=$(realpath "${dir}")
                else
                    abs_dir=$(cd "${dir}" && pwd)
                fi
                
                local basename=$(basename "${abs_dir}")
                
                # Skip if directory name contains problematic characters
                if [[ -z "${basename}" ]] || [[ "${basename}" =~ [[:space:]] ]] || [[ "${basename}" =~ \.\. ]]; then
                    log "Warning: Skipping directory with problematic name: ${basename}"
                    continue
                fi
                
                # Apply TLD filtering if --prefer-tld-dirs is enabled
                if [ "${PREFER_TLD_DIRS}" == "yes" ]; then
                    if ! is_domain_like "${basename}"; then
                        verbose_log "Skipping directory '${basename}' (does not match domain pattern)"
                        continue
                    fi
                fi
                
                local mount_binding="${abs_dir}::sites/${basename}"
                echo "${mount_binding}" >> "${temp_file}"
                binding_count=$((binding_count + 1))
                
                verbose_log "Added binding: ${mount_binding}"
            fi
        done
    fi
    
    if [ ${binding_count} -eq 0 ]; then
        log "Warning: No directories found in ${abs_target_dir}"
        rm -f "${temp_file}"
        return 1
    fi
    
    # Sort the bindings for consistent output
    sort "${temp_file}" > "${output_file}"
    rm -f "${temp_file}"
    
    log "Successfully created mount bindings file: ${output_file}"
    log "Generated ${binding_count} mount binding(s)"
    
    # Display the contents if verbose mode is enabled
    if [ "${VERBOSE_MODE}" == "yes" ]; then
        log "Mount bindings file contents:"
        while IFS= read -r line; do
            log "  ${line}"
        done < "${output_file}"
    else
        log "Use --verbose to see the generated bindings, or check: ${output_file}"
    fi
    
    return 0
}

# Function to check mount status and report
check_mount_status() {
    local mount_pair="$1"
    local source_path="${mount_pair%%::*}"
    local dest_path="${mount_pair##*::}"
    local dest_dir_in_chroot="${HOME_DIR}/${dest_path}"
    
    log "Checking mount status for: ${source_path} -> ${dest_path}"
    
    # Check if source exists
    if [ -d "${source_path}" ]; then
        log "  ✓ Source directory exists: ${source_path}"
        local source_files=$(find "${source_path}" -maxdepth 1 -type f | wc -l)
        log "  ✓ Source contains ${source_files} files"
        
        # Show ownership information in verbose mode
        if [ "${VERBOSE_MODE}" == "yes" ]; then
            local owner=$(stat -c '%U' "${source_path}" 2>/dev/null || echo "unknown")
            local group=$(stat -c '%G' "${source_path}" 2>/dev/null || echo "unknown")
            local perms=$(stat -c '%a' "${source_path}" 2>/dev/null || echo "unknown")
            verbose_log "  Source ownership: ${owner}:${group} (${perms})"
            
            # Check if FTP user is in the group
            if groups "${FTP_USER}" 2>/dev/null | grep -q "\b${group}\b"; then
                verbose_log "  ✓ FTP user ${FTP_USER} is in group ${group}"
            else
                verbose_log "  ✗ FTP user ${FTP_USER} is NOT in group ${group}"
            fi
        fi
    else
        log "  ✗ Source directory missing: ${source_path}"
        return 1
    fi
    
    # Check if destination exists
    if [ -d "${dest_dir_in_chroot}" ]; then
        log "  ✓ Destination directory exists: ${dest_dir_in_chroot}"
    else
        log "  ✗ Destination directory missing: ${dest_dir_in_chroot}"
        return 1
    fi
    
    # Check if mount is active
    if mountpoint -q "${dest_dir_in_chroot}"; then
        log "  ✓ Mount is active"
        local dest_files=$(find "${dest_dir_in_chroot}" -maxdepth 1 -type f 2>/dev/null | wc -l)
        log "  ✓ Mounted directory contains ${dest_files} files"
    else
        log "  ✗ Mount is not active"
        return 1
    fi
    
    # Check fstab entry
    local fstab_entry="${source_path} ${dest_dir_in_chroot} none rw,rbind 0 0"
    if grep -Fxq "${fstab_entry}" /etc/fstab 2>/dev/null; then
        log "  ✓ Fstab entry exists"
    else
        log "  ✗ Fstab entry missing"
        return 1
    fi
    
    return 0
}

# Function to parse bind mounts from a file
parse_bind_mounts_file() {
    local file_path="$1"
    
    if [ ! -f "${file_path}" ]; then
        error_exit "Bind mounts file '${file_path}' does not exist or is not readable."
    fi
    
    log "Parsing bind mounts from file: ${file_path}"
    
    # Clear existing bind mounts
    BIND_MOUNTS=()
    
    local line_number=0
    local valid_mounts=0
    
    while IFS= read -r line || [ -n "$line" ]; do
        line_number=$((line_number + 1))
        
        # Skip empty lines and comments (lines starting with # or //)
        if [[ -z "$line" ]] || [[ "$line" =~ ^[[:space:]]*# ]] || [[ "$line" =~ ^[[:space:]]*// ]]; then
            continue
        fi
        
        # Trim leading and trailing whitespace
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # Skip empty lines after trimming
        if [[ -z "$line" ]]; then
            continue
        fi
        
        # Validate format: must contain "::" separator
        if [[ ! "$line" =~ :: ]]; then
            log "Warning: Line ${line_number} in '${file_path}' is invalid (missing '::' separator): ${line}"
            continue
        fi
        
        # Extract source and destination paths
        local source_path="${line%%::*}"
        local dest_path="${line##*::}"
        
        # Trim whitespace from paths
        source_path=$(echo "$source_path" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        dest_path=$(echo "$dest_path" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # Validate that both paths are not empty
        if [[ -z "$source_path" ]] || [[ -z "$dest_path" ]]; then
            log "Warning: Line ${line_number} in '${file_path}' has empty source or destination path: ${line}"
            continue
        fi
        
        # Validate that destination path doesn't start with / (should be relative to chroot)
        if [[ "$dest_path" =~ ^/ ]]; then
            log "Warning: Line ${line_number} in '${file_path}' has absolute destination path (should be relative): ${line}"
            log "         Converting '${dest_path}' to '${dest_path#/}'"
            dest_path="${dest_path#/}"
        fi
        
        # Add the validated mount pair
        BIND_MOUNTS+=("${source_path}::${dest_path}")
        valid_mounts=$((valid_mounts + 1))
        
        if [ "${DRY_RUN}" == "yes" ]; then
            log "DRY RUN: Would add bind mount: '${source_path}' -> '${dest_path}'"
        else
            log "Added bind mount from file: '${source_path}' -> '${dest_path}'"
        fi
        
    done < "${file_path}"
    
    log "Parsed ${valid_mounts} valid bind mount(s) from '${file_path}' (${line_number} total lines processed)"
    
    if [ ${valid_mounts} -eq 0 ]; then
        error_exit "No valid bind mounts found in file '${file_path}'. Please check the file format."
    fi
}

# Function to validate permission arguments
validate_permission_arguments() {
    # Check for mutually exclusive permission flags
    local perm_flags_count=0
    
    if [ "${SET_PERMS_FOR_USER}" == "yes" ]; then
        perm_flags_count=$((perm_flags_count + 1))
    fi
    
    if [ "${SET_PERMS}" == "yes" ]; then
        perm_flags_count=$((perm_flags_count + 1))
    fi
    
    if [ ${perm_flags_count} -gt 1 ]; then
        error_exit "Permission flags --set-perms-for-user and --set-perms are mutually exclusive. Please use only one."
    fi
    
    # Validate that --normalize-perms only works with --keep-original-owner
    if [ "${NORMALIZE_PERMS}" == "yes" ] && [ "${KEEP_ORIGINAL_OWNER}" != "yes" ]; then
        error_exit "--normalize-perms can only be used with --keep-original-owner."
    fi
    
    # Validate permission values are provided if flags are set
    if [ "${SET_PERMS_FOR_USER}" == "yes" ] && [ -z "${USER_PERMS}" ]; then
        error_exit "Permission value is required with --set-perms-for-user."
    fi
    
    if [ "${SET_PERMS}" == "yes" ] && [ -z "${ALL_PERMS}" ]; then
        error_exit "Permission value is required with --set-perms."
    fi
}

# Function to parse command-line arguments
parse_arguments() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -u|--user)
                FTP_USER="$2"
                HOME_DIR="/home/${FTP_USER}"
                shift 2
                ;;
            -b|--bind-mounts)
                # Check if the argument is a file path or space-separated mounts
                if [ -f "$2" ]; then
                    # It's a file - parse bind mounts from file
                    parse_bind_mounts_file "$2"
                else
                    # It's space-separated mounts - use existing logic
                    BIND_MOUNTS=()
                    IFS=' ' read -r -a mounts_array <<< "$2"
                    for mount_pair in "${mounts_array[@]}"; do
                        # Validate format
                        if [[ ! "$mount_pair" =~ :: ]]; then
                            error_exit "Invalid bind mount format: '${mount_pair}'. Expected format: 'source::destination'"
                        fi
                        BIND_MOUNTS+=("$mount_pair")
                    done
                fi
                shift 2
                ;;
            -w|--writable-chroot)
                ALLOW_WRITEABLE_CHROOT="yes"
                shift
                ;;
            -f|--firewall)
                FIREWALL_TYPE="$2"
                shift 2
                ;;
            -p|--pasv-ports)
                IFS=':' read -r PASV_MIN_PORT PASV_MAX_PORT <<< "$2"
                if [[ -z "$PASV_MIN_PORT" || -z "$PASV_MAX_PORT" ]]; then
                    error_exit "Invalid passive port format. Use min:max (e.g., 40000:50000)."
                fi
                shift 2
                ;;
            --add-mounts-only)
                ADD_MOUNTS_ONLY="yes"
                shift
                ;;
            --generate-password)
                GENERATE_PASSWORD="yes"
                shift
                ;;
            --set-password)
                SET_PASSWORD="yes"
                USER_PASSWORD="$2"
                if [[ -z "$USER_PASSWORD" ]]; then
                    error_exit "Password cannot be empty. Please provide a password with --set-password."
                fi
                shift 2
                ;;
            --verbose)
                VERBOSE_MODE="yes"
                shift
                ;;
            --check-mounts)
                CHECK_MOUNTS_ONLY="yes"
                shift
                ;;
            --prep-mount-bindings)
                PREP_MOUNT_BINDINGS="yes"
                # Check if next argument is a directory (not starting with -)
                if [[ $# -gt 1 && ! "$2" =~ ^- ]]; then
                    PREP_MOUNT_BINDINGS_DIR="$2"
                    shift 2
                else
                    PREP_MOUNT_BINDINGS_DIR="$(pwd)"
                    shift
                fi
                ;;
            --process-mount-bindings)
                PROCESS_MOUNT_BINDINGS="yes"
                # Check if next argument is a directory (not starting with -)
                if [[ $# -gt 1 && ! "$2" =~ ^- ]]; then
                    PROCESS_MOUNT_BINDINGS_DIR="$2"
                    shift 2
                else
                    PROCESS_MOUNT_BINDINGS_DIR="$(pwd)"
                    shift
                fi
                ;;
            --prefer-tld-dirs)
                PREFER_TLD_DIRS="yes"
                shift
                ;;
            --keep-original-owner)
                KEEP_ORIGINAL_OWNER="yes"
                shift
                ;;
            --normalize-perms)
                NORMALIZE_PERMS="yes"
                shift
                ;;
            --set-perms-for-user)
                SET_PERMS_FOR_USER="yes"
                USER_PERMS="$2"
                if [[ -z "$USER_PERMS" ]]; then
                    error_exit "Permission value is required with --set-perms-for-user. Please provide a value (e.g., 755)."
                fi
                # Validate permission format (3 or 4 digit octal)
                if [[ ! "$USER_PERMS" =~ ^[0-7]{3,4}$ ]]; then
                    error_exit "Invalid permission format: '${USER_PERMS}'. Please use octal format (e.g., 755, 0755)."
                fi
                shift 2
                ;;
            --set-perms)
                SET_PERMS="yes"
                ALL_PERMS="$2"
                if [[ -z "$ALL_PERMS" ]]; then
                    error_exit "Permission value is required with --set-perms. Please provide a value (e.g., 775)."
                fi
                # Validate permission format (3 or 4 digit octal)
                if [[ ! "$ALL_PERMS" =~ ^[0-7]{3,4}$ ]]; then
                    error_exit "Invalid permission format: '${ALL_PERMS}'. Please use octal format (e.g., 775, 0775)."
                fi
                shift 2
                ;;
            --dry-run)
                DRY_RUN="yes"
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                error_exit "Unknown option: $1"
                ;;
        esac
    done
}

# Function to create the system user and set up home directory permissions
create_user_and_dirs() {
    log "1. Creating FTP user '${FTP_USER}' and home directory structure..."

    # Check if user exists, create if not
    USER_CREATED="no"
    if ! id "${FTP_USER}" &>/dev/null; then
        execute_or_log "Creating user ${FTP_USER}" sudo adduser --disabled-password --gecos "" "${FTP_USER}" || error_exit "Failed to add user ${FTP_USER}."
        log "User '${FTP_USER}' created."
        USER_CREATED="yes"
    else
        log "User '${FTP_USER}' already exists. Skipping user creation."
    fi

    # Handle password setting if requested
    if [ "${GENERATE_PASSWORD}" == "yes" ] || [ "${SET_PASSWORD}" == "yes" ]; then
        # Check for conflicting password options
        if [ "${GENERATE_PASSWORD}" == "yes" ] && [ "${SET_PASSWORD}" == "yes" ]; then
            error_exit "Cannot use both --generate-password and --set-password. Please choose one."
        fi
        
        if [ "${USER_CREATED}" == "yes" ] || [ "${ADD_MOUNTS_ONLY}" != "yes" ]; then
            local password_to_set=""
            local password_source=""
            
            if [ "${GENERATE_PASSWORD}" == "yes" ]; then
                log "Generating temporary password for user '${FTP_USER}'..."
                password_to_set=$(generate_temp_password)
                password_source="generated"
                
                if [ -z "${password_to_set}" ]; then
                    error_exit "Failed to generate temporary password."
                fi
            elif [ "${SET_PASSWORD}" == "yes" ]; then
                log "Setting specified password for user '${FTP_USER}'..."
                password_to_set="${USER_PASSWORD}"
                password_source="specified"
                
                # Basic password validation
                if [ ${#password_to_set} -lt 4 ]; then
                    error_exit "Password too short. Please use at least 4 characters."
                fi
            fi
            
            if [ -n "${password_to_set}" ]; then
                execute_or_log "Setting ${password_source} password" set_user_password "${FTP_USER}" "${password_to_set}" || error_exit "Failed to set password for user ${FTP_USER}."
                
                if [ "${DRY_RUN}" == "no" ]; then
                    log "SUCCESS: Password set for user '${FTP_USER}'"
                    if [ "${password_source}" == "generated" ]; then
                        log "============================================"
                        log "TEMPORARY PASSWORD: ${password_to_set}"
                        log "============================================"
                        log "IMPORTANT: Please save this password securely and consider changing it after first login!"
                    else
                        log "User password has been set to the specified value."
                        log "IMPORTANT: Please ensure you remember this password for FTP access!"
                    fi
                else
                    log "DRY RUN: Would set ${password_source} password for user '${FTP_USER}'"
                fi
            fi
        else
            log "Password setting requested but user already exists and add-mounts-only mode is active. Skipping password setting."
        fi
    fi

    # Ensure home directory exists and set secure permissions
    execute_or_log "Creating home directory ${HOME_DIR}" sudo mkdir -p "${HOME_DIR}" || error_exit "Failed to create home directory ${HOME_DIR}."
    execute_or_log "Setting ownership of ${HOME_DIR} to root" sudo chown root:root "${HOME_DIR}" || error_exit "Failed to set ownership of ${HOME_DIR} to root."
    execute_or_log "Setting permissions of ${HOME_DIR}" sudo chmod 755 "${HOME_DIR}" || error_exit "Failed to set permissions of ${HOME_DIR}."
    log "Set secure permissions for ${HOME_DIR} (owned by root, chmod 755)."

    # Create a writable 'uploads' directory inside home (for direct uploads)
    UPLOAD_DIR="${HOME_DIR}/uploads"
    execute_or_log "Creating writable uploads directory ${UPLOAD_DIR}" sudo mkdir -p "${UPLOAD_DIR}" || error_exit "Failed to create uploads directory ${UPLOAD_DIR}."
    execute_or_log "Setting ownership of ${UPLOAD_DIR}" sudo chown "${FTP_USER}:${FTP_USER}" "${UPLOAD_DIR}" || error_exit "Failed to set ownership of ${UPLOAD_DIR}."
    
    # Set permissions based on flags
    local upload_perms="775"  # default
    if [ "${SET_PERMS}" == "yes" ]; then
        upload_perms="${ALL_PERMS}"
        verbose_log "Using --set-perms value ${ALL_PERMS} for uploads directory"
    elif [ "${SET_PERMS_FOR_USER}" == "yes" ]; then
        upload_perms="${USER_PERMS}"
        verbose_log "Using --set-perms-for-user value ${USER_PERMS} for uploads directory"
    fi
    
    execute_or_log "Setting permissions of ${UPLOAD_DIR}" sudo chmod "${upload_perms}" "${UPLOAD_DIR}" || error_exit "Failed to set permissions of ${UPLOAD_DIR}."
    log "Created writable uploads directory: ${UPLOAD_DIR} (permissions: ${upload_perms})."

    # Create destination directories for bind mounts and set ownership
    for mount_pair in "${BIND_MOUNTS[@]}"; do
        # Validate mount configuration
        if ! validate_mount_config "${mount_pair}"; then
            error_exit "Invalid mount configuration: ${mount_pair}"
        fi
        
        verbose_log "Processing mount pair: ${mount_pair}"
        
        # Extract destination path - Assuming format "SOURCE::DEST"
        # Using string manipulation to get the part after the first "::"
        DEST_PATH="${mount_pair##*::}"
        DEST_DIR_IN_CHROOT="${HOME_DIR}/${DEST_PATH}"

        execute_or_log "Creating bind-mount destination directory ${DEST_DIR_IN_CHROOT}" sudo mkdir -p "${DEST_DIR_IN_CHROOT}" || error_exit "Failed to create destination directory ${DEST_DIR_IN_CHROOT}."
        execute_or_log "Setting ownership of ${DEST_DIR_IN_CHROOT}" sudo chown "${FTP_USER}:${FTP_USER}" "${DEST_DIR_IN_CHROOT}" || error_exit "Failed to set ownership of ${DEST_DIR_IN_CHROOT}."
        
        # Set permissions based on flags
        local dest_perms="755"  # default
        if [ "${SET_PERMS}" == "yes" ]; then
            dest_perms="${ALL_PERMS}"
            verbose_log "Using --set-perms value ${ALL_PERMS} for destination directory"
        elif [ "${SET_PERMS_FOR_USER}" == "yes" ]; then
            dest_perms="${USER_PERMS}"
            verbose_log "Using --set-perms-for-user value ${USER_PERMS} for destination directory"
        fi
        
        execute_or_log "Setting permissions of ${DEST_DIR_IN_CHROOT}" sudo chmod "${dest_perms}" "${DEST_DIR_IN_CHROOT}" || error_exit "Failed to set permissions of ${DEST_DIR_IN_CHROOT}."
        log "Created bind-mount destination directory: ${DEST_DIR_IN_CHROOT} (permissions: ${dest_perms})."
    done
}

# Function to add mounts to existing user (for --add-mounts-only mode)
add_mounts_to_existing_user() {
    log "Adding new mounts to existing user '${FTP_USER}'..."

    # Check if user exists
    if ! id "${FTP_USER}" &>/dev/null; then
        error_exit "User '${FTP_USER}' does not exist. Cannot add mounts to non-existent user."
    fi

    # Ensure home directory exists
    if [ ! -d "${HOME_DIR}" ]; then
        error_exit "Home directory '${HOME_DIR}' does not exist for user '${FTP_USER}'."
    fi

    log "User '${FTP_USER}' exists with home directory '${HOME_DIR}'. Proceeding with mount additions."

    # Create destination directories for new bind mounts
    for mount_pair in "${BIND_MOUNTS[@]}"; do
        # Validate mount configuration
        if ! validate_mount_config "${mount_pair}"; then
            error_exit "Invalid mount configuration: ${mount_pair}"
        fi
        
        verbose_log "Processing new mount pair: ${mount_pair}"
        
        DEST_PATH="${mount_pair##*::}"
        DEST_DIR_IN_CHROOT="${HOME_DIR}/${DEST_PATH}"

        # Check if mount already exists
        FSTAB_ENTRY="${mount_pair%%::*} ${DEST_DIR_IN_CHROOT} none rw,rbind 0 0"
        if grep -Fxq "${FSTAB_ENTRY}" /etc/fstab; then
            log "Mount '${mount_pair}' already exists in fstab. Skipping."
            continue
        fi

        add_fstab_entry "${FSTAB_ENTRY}" "Bind mount for ${SOURCE_PATH} to ${DEST_DIR_IN_CHROOT}"

        # Check if mount point already exists
        if mountpoint -q "${DEST_DIR_IN_CHROOT}"; then
            log "Mount point '${DEST_DIR_IN_CHROOT}' is already mounted. Skipping."
            continue
        fi

        execute_or_log "Creating bind-mount destination directory ${DEST_DIR_IN_CHROOT}" sudo mkdir -p "${DEST_DIR_IN_CHROOT}" || error_exit "Failed to create destination directory ${DEST_DIR_IN_CHROOT}."
        execute_or_log "Setting ownership of ${DEST_DIR_IN_CHROOT}" sudo chown "${FTP_USER}:${FTP_USER}" "${DEST_DIR_IN_CHROOT}" || error_exit "Failed to set ownership of ${DEST_DIR_IN_CHROOT}."
        
        # Set permissions based on flags
        local dest_perms="755"  # default
        if [ "${SET_PERMS}" == "yes" ]; then
            dest_perms="${ALL_PERMS}"
            verbose_log "Using --set-perms value ${ALL_PERMS} for destination directory"
        elif [ "${SET_PERMS_FOR_USER}" == "yes" ]; then
            dest_perms="${USER_PERMS}"
            verbose_log "Using --set-perms-for-user value ${USER_PERMS} for destination directory"
        fi
        
        execute_or_log "Setting permissions of ${DEST_DIR_IN_CHROOT}" sudo chmod "${dest_perms}" "${DEST_DIR_IN_CHROOT}" || error_exit "Failed to set permissions of ${DEST_DIR_IN_CHROOT}."
        log "Created bind-mount destination directory: ${DEST_DIR_IN_CHROOT} (permissions: ${dest_perms})."
        
    done

    # Set up the new bind mounts
    for mount_pair in "${BIND_MOUNTS[@]}"; do
        SOURCE_PATH="${mount_pair%%::*}"
        DEST_PATH="${mount_pair##*::}"
        DEST_DIR_IN_CHROOT="${HOME_DIR}/${DEST_PATH}"

        # Check if mount already exists
        FSTAB_ENTRY="${SOURCE_PATH} ${DEST_DIR_IN_CHROOT} none rw,rbind 0 0"
        if grep -Fxq "${FSTAB_ENTRY}" /etc/fstab; then
            log "Mount '${mount_pair}' already exists in fstab. Skipping setup."
            continue
        fi

        # Add to /etc/fstab for persistence
        add_fstab_entry "${FSTAB_ENTRY}" "Bind mount for ${SOURCE_PATH} to ${DEST_DIR_IN_CHROOT}"

        if mountpoint -q "${DEST_DIR_IN_CHROOT}"; then
            log "Mount point '${DEST_DIR_IN_CHROOT}' is already mounted. Skipping setup."
            continue
        fi

        # Ensure source directory exists and has appropriate permissions
        setup_source_directory_permissions "${SOURCE_PATH}" "${FTP_USER}"

        # Perform the bind mount
        execute_or_log "Bind mounting ${SOURCE_PATH} to ${DEST_DIR_IN_CHROOT}" sudo mount --rbind "${SOURCE_PATH}" "${DEST_DIR_IN_CHROOT}" || error_exit "Failed to bind mount ${SOURCE_PATH} to ${DEST_DIR_IN_CHROOT}."
        log "Bind mounted '${SOURCE_PATH}' to '${DEST_DIR_IN_CHROOT}'."
        
    done

    log "Successfully added ${#BIND_MOUNTS[@]} new mount(s) to user '${FTP_USER}'."
}

# Function to set up source directories and bind mounts
setup_bind_mounts() {
    log "2. Setting up source directories and bind mounts..."

    for mount_pair in "${BIND_MOUNTS[@]}"; do
        # Validate mount configuration
        if ! validate_mount_config "${mount_pair}"; then
            error_exit "Invalid mount configuration: ${mount_pair}"
        fi
        
        verbose_log "Setting up bind mount: ${mount_pair}"
        
        # Extract source and destination paths
        SOURCE_PATH="${mount_pair%%::*}" # Get part before "::"
        DEST_PATH="${mount_pair##*::}"   # Get part after "::"
        DEST_DIR_IN_CHROOT="${HOME_DIR}/${DEST_PATH}"

        # Ensure source directory exists and has appropriate permissions
        setup_source_directory_permissions "${SOURCE_PATH}" "${FTP_USER}"

        # Check if mount already exists
        FSTAB_ENTRY="${SOURCE_PATH} ${DEST_DIR_IN_CHROOT} none rw,rbind 0 0"
        if grep -Fxq "${FSTAB_ENTRY}" /etc/fstab; then
            log "Mount '${mount_pair}' already exists in fstab. Skipping setup."
            continue
        fi

        add_fstab_entry "${FSTAB_ENTRY}" "Bind mount for ${SOURCE_PATH} to ${DEST_DIR_IN_CHROOT}"

        # Perform the bind mount
        if ! mountpoint -q "${DEST_DIR_IN_CHROOT}"; then
            execute_or_log "Bind mounting ${SOURCE_PATH} to ${DEST_DIR_IN_CHROOT}" sudo mount --rbind "${SOURCE_PATH}" "${DEST_DIR_IN_CHROOT}" || error_exit "Failed to bind mount ${SOURCE_PATH} to ${DEST_DIR_IN_CHROOT}."
            log "Bind mounted '${SOURCE_PATH}' to '${DEST_DIR_IN_CHROOT}'."
        else
            log "Mount point '${DEST_DIR_IN_CHROOT}' is already mounted. Skipping."
        fi
    
    done
}

# Function to clean up any accidentally leaked log timestamps from vsftpd.conf
clean_vsftpd_config_timestamps() {
    local config_file="${VSFTPD_CONF}"
    
    if [ "${DRY_RUN}" == "yes" ]; then
        log "DRY RUN: Would clean any timestamp entries from ${config_file}"
        return 0
    fi
    
    if [ ! -f "${config_file}" ]; then
        return 0  # File doesn't exist, nothing to clean
    fi
    
    # Remove any lines that look like timestamps: [YYYY-MM-DD HH:MM:SS]
    # Also remove lines with [DRY RUN] prefix that might have leaked
    local lines_removed=0
    
    # Count lines before cleanup
    local lines_before=$(wc -l < "${config_file}" 2>/dev/null || echo "0")
    
    # Remove timestamp lines and dry run lines
    sudo sed -i '/^\[20[0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\]/d' "${config_file}" 2>/dev/null
    sudo sed -i '/^\[DRY RUN\]/d' "${config_file}" 2>/dev/null
    
    # Count lines after cleanup
    local lines_after=$(wc -l < "${config_file}" 2>/dev/null || echo "0")
    lines_removed=$((lines_before - lines_after))
    
    if [ ${lines_removed} -gt 0 ]; then
        log "Cleaned ${lines_removed} timestamp/log entries from ${config_file}"
    fi
}

# Function to add or update a configuration parameter in vsftpd.conf
add_or_update_vsftpd_config() {
    local key="$1"
    local value="$2"
    local config_file="${VSFTPD_CONF}"
    
    if [ "${DRY_RUN}" == "yes" ]; then
        log "DRY RUN: Would set ${key}=${value} in ${config_file}"
        return 0
    fi
    
    # Check if the key already exists with the correct value
    if grep -q "^${key}=${value}$" "${config_file}" 2>/dev/null; then
        log "Configuration ${key}=${value} already exists with correct value. Skipping."
        return 0
    fi
    
    # Remove any existing instances of this key (including commented ones)
    sudo sed -i "/^#*${key}=/d" "${config_file}" 2>/dev/null
    
    # Add the new configuration using a temporary variable to avoid any logging contamination
    # Create the config line in a variable first
    local config_line="${key}=${value}"
    
    # Write the configuration line directly to the file using printf to avoid any shell interpretation
    # Use a subshell to completely isolate the file write operation
    (
        # Redirect all output to prevent any accidental logging contamination
        exec 1>/dev/null 2>/dev/null
        # Write the config line using printf which is more reliable than echo
        printf '%s\n' "${config_line}" | sudo tee -a "${config_file}" >/dev/null 2>&1
    )
    
    # Verify the write was successful by checking if the line exists
    if grep -q "^${key}=${value}$" "${config_file}" 2>/dev/null; then
        log "Added/updated configuration: ${key}=${value}"
    else
        error_exit "Failed to write configuration ${key}=${value} to ${config_file}"
    fi
}

# Function to configure vsftpd
configure_vsftpd() {
    log "3. Configuring vsftpd..."

    # Backup original vsftpd.conf
    if [ -f "${VSFTPD_CONF}" ] && [ ! -f "${VSFTPD_CONF}.bak" ]; then
        execute_or_log "Backing up ${VSFTPD_CONF}" sudo cp "${VSFTPD_CONF}" "${VSFTPD_CONF}.bak" || error_exit "Failed to backup vsftpd.conf."
        log "Backed up ${VSFTPD_CONF} to ${VSFTPD_CONF}.bak."
    else
        log "Skipping vsftpd.conf backup (file doesn't exist or backup already present)."
    fi

    # Create vsftpd.conf if it doesn't exist
    if [ ! -f "${VSFTPD_CONF}" ]; then
        execute_or_log "Creating ${VSFTPD_CONF}" sudo touch "${VSFTPD_CONF}" || error_exit "Failed to create ${VSFTPD_CONF}."
        log "Created ${VSFTPD_CONF}."
    fi

    # Clean up any accidentally leaked timestamps from previous runs
    clean_vsftpd_config_timestamps

    log "Configuring vsftpd settings (checking for existing values)..."
    
    # Add or update each configuration parameter
    add_or_update_vsftpd_config "listen" "NO"
    add_or_update_vsftpd_config "listen_ipv6" "YES"
    add_or_update_vsftpd_config "anonymous_enable" "NO"
    add_or_update_vsftpd_config "local_enable" "YES"
    add_or_update_vsftpd_config "write_enable" "YES"
    add_or_update_vsftpd_config "chroot_local_user" "YES"
    add_or_update_vsftpd_config "allow_writeable_chroot" "${ALLOW_WRITEABLE_CHROOT}"
    add_or_update_vsftpd_config "pasv_enable" "YES"
    add_or_update_vsftpd_config "pasv_min_port" "${PASV_MIN_PORT}"
    add_or_update_vsftpd_config "pasv_max_port" "${PASV_MAX_PORT}"
    add_or_update_vsftpd_config "xferlog_enable" "YES"
    add_or_update_vsftpd_config "xferlog_file" "/var/log/vsftpd.log"
    add_or_update_vsftpd_config "xferlog_std_format" "YES"

    log "Updated ${VSFTPD_CONF} with chroot, passive mode, and logging settings."
}

# Function to configure firewall rules
setup_firewall() {
    log "4. Configuring firewall (${FIREWALL_TYPE})..."

    if [ "${FIREWALL_TYPE}" == "ufw" ]; then
        if ! command_exists ufw; then
            log "UFW not found. Installing UFW..."
            if [ "${DRY_RUN}" == "no" ]; then
                sudo apt-get update && sudo apt-get install -y ufw || error_exit "Failed to install UFW."
            else
                log "DRY RUN: Would execute: sudo apt-get update && sudo apt-get install -y ufw"
            fi
        fi
        execute_or_log "Adding UFW rule for port 20" sudo ufw allow 20/tcp || error_exit "Failed to add UFW rule for port 20."
        execute_or_log "Adding UFW rule for port 21" sudo ufw allow 21/tcp || error_exit "Failed to add UFW rule for port 21."
        execute_or_log "Adding UFW rule for passive ports" sudo ufw allow "${PASV_MIN_PORT}:${PASV_MAX_PORT}/tcp" || error_exit "Failed to add UFW rule for passive ports."
        execute_or_log "Reloading UFW" sudo ufw reload || error_exit "Failed to reload UFW."
        log "UFW configured for FTP ports."
    elif [ "${FIREWALL_TYPE}" == "firewalld" ]; then
        if ! command_exists firewall-cmd; then
            log "Firewalld not found. Please install firewalld (e.g., sudo yum install firewalld)."
            error_exit "Firewalld not installed."
        fi
        execute_or_log "Adding firewalld rule for port 21" sudo firewall-cmd --permanent --add-port=21/tcp || error_exit "Failed to add firewalld rule for port 21."
        execute_or_log "Adding firewalld rule for port 20" sudo firewall-cmd --permanent --add-port=20/tcp || error_exit "Failed to add firewalld rule for port 20."
        execute_or_log "Adding firewalld rule for passive ports" sudo firewall-cmd --permanent --add-port="${PASV_MIN_PORT}-${PASV_MAX_PORT}/tcp" || error_exit "Failed to add firewalld rule for passive ports."
        execute_or_log "Reloading firewalld" sudo firewall-cmd --reload || error_exit "Failed to reload firewalld."
        log "Firewalld configured for FTP ports."
    elif [ "${FIREWALL_TYPE}" == "none" ]; then
        log "Skipping firewall configuration as requested."
    else
        log "Unknown firewall type specified: ${FIREWALL_TYPE}. Skipping firewall configuration."
    fi
}

# Main function to orchestrate the setup
main() {
    # Parse command-line arguments first (to handle --help without root check)
    parse_arguments "$@"
    
    # Validate permission arguments
    validate_permission_arguments
    
    # Check for root privileges (skip for help)
    if [[ $EUID -ne 0 ]]; then
        error_exit "This script must be run as root. Please use sudo."
    fi

    # Clean up any existing fstab contamination from previous runs
    clean_fstab_timestamps
    
    # Remove duplicate fstab entries
    remove_duplicate_fstab_entries

    # Handle check-mounts-only mode
    if [ "${CHECK_MOUNTS_ONLY}" == "yes" ]; then
        log "Mount status check mode enabled for user: '${FTP_USER}'"
        log "Home directory: '${HOME_DIR}'"
        log "Checking ${#BIND_MOUNTS[@]} bind mount(s)..."
        echo ""
        
        local failed_mounts=0
        for mount_pair in "${BIND_MOUNTS[@]}"; do
            if ! check_mount_status "${mount_pair}"; then
                failed_mounts=$((failed_mounts + 1))
            fi
            echo ""
        done
        
        if [ ${failed_mounts} -eq 0 ]; then
            log "✓ All ${#BIND_MOUNTS[@]} mount(s) are healthy!"
        else
            log "✗ ${failed_mounts} out of ${#BIND_MOUNTS[@]} mount(s) have issues."
            exit 1
        fi
        return 0
    fi

    # Handle prep-mount-bindings mode
    if [ "${PREP_MOUNT_BINDINGS}" == "yes" ]; then
        log "Prep mount bindings mode enabled"
        log "Target directory: '${PREP_MOUNT_BINDINGS_DIR}'"
        log "TLD filtering enabled: ${PREFER_TLD_DIRS}"
        log "Verbose mode: ${VERBOSE_MODE}"
        log "Dry run enabled: ${DRY_RUN}"
        echo ""
        
        # Generate output filename with timestamp
        local timestamp=$(date +%Y%m%d_%H%M%S)
        local output_file="mount_bindings_${timestamp}.txt"
        
        if prep_mount_bindings "${PREP_MOUNT_BINDINGS_DIR}" "${output_file}"; then
            log "Mount bindings preparation completed successfully!"
            if [ "${DRY_RUN}" == "no" ]; then
                log "You can now use this file with: --bind-mounts ${output_file}"
            fi
        else
            error_exit "Failed to prepare mount bindings"
        fi
        return 0
    fi

    # Handle process-mount-bindings mode
    if [ "${PROCESS_MOUNT_BINDINGS}" == "yes" ]; then
        log "Process mount bindings mode enabled"
        log "Target directory: '${PROCESS_MOUNT_BINDINGS_DIR}'"
        log "FTP user: '${FTP_USER}'"
        log "Home directory: '${HOME_DIR}'"
        log "TLD filtering enabled: ${PREFER_TLD_DIRS}"
        log "Keep original owner: ${KEEP_ORIGINAL_OWNER}"
        log "Verbose mode: ${VERBOSE_MODE}"
        log "Dry run enabled: ${DRY_RUN}"
        echo ""
        
        # Process the mount bindings directly
        if process_mount_bindings "${PROCESS_MOUNT_BINDINGS_DIR}" "${FTP_USER}" "${HOME_DIR}"; then
            log "Mount bindings processed successfully! Proceeding with full FTP setup..."
            echo ""
            # Continue with the full setup process using the populated BIND_MOUNTS array
        else
            error_exit "Failed to process mount bindings from directory"
        fi
        # Don't return here - continue with full setup
    fi

    # Handle add-mounts-only mode
    if [ "${ADD_MOUNTS_ONLY}" == "yes" ]; then
        log "Add-mounts-only mode enabled for user: '${FTP_USER}'"
        log "Home directory: '${HOME_DIR}'"
        log "New bind mounts to add: ${BIND_MOUNTS[@]}"
        log "Keep original owner: ${KEEP_ORIGINAL_OWNER}"
        log "Normalize permissions: ${NORMALIZE_PERMS}"
        log "Set permissions for user: ${SET_PERMS_FOR_USER}"
        if [ "${SET_PERMS_FOR_USER}" == "yes" ]; then
            log "User permissions value: ${USER_PERMS}"
        fi
        log "Set permissions for all: ${SET_PERMS}"
        if [ "${SET_PERMS}" == "yes" ]; then
            log "All permissions value: ${ALL_PERMS}"
        fi
        log "Dry run enabled: ${DRY_RUN}"
        echo ""

        add_mounts_to_existing_user
        log "Mount addition complete! New mounts have been added to user '${FTP_USER}'."
        return 0
    fi

    log "Starting vsftpd setup for user: '${FTP_USER}'"
    log "Home directory: '${HOME_DIR}'"
    log "Bind mounts: ${BIND_MOUNTS[@]}"
    log "Allow writable chroot: ${ALLOW_WRITEABLE_CHROOT}"
    log "Passive ports: ${PASV_MIN_PORT}-${PASV_MAX_PORT}"
    log "Firewall type: ${FIREWALL_TYPE}"
    log "Keep original owner: ${KEEP_ORIGINAL_OWNER}"
    log "Normalize permissions: ${NORMALIZE_PERMS}"
    log "Set permissions for user: ${SET_PERMS_FOR_USER}"
    if [ "${SET_PERMS_FOR_USER}" == "yes" ]; then
        log "User permissions value: ${USER_PERMS}"
    fi
    log "Set permissions for all: ${SET_PERMS}"
    if [ "${SET_PERMS}" == "yes" ]; then
        log "All permissions value: ${ALL_PERMS}"
    fi
    log "Dry run enabled: ${DRY_RUN}"
    log "Verbose mode enabled: ${VERBOSE_MODE}"
    echo ""
    
    # Validate configuration
    verbose_log "Validating configuration..."
    if [ ${PASV_MIN_PORT} -ge ${PASV_MAX_PORT} ]; then
        error_exit "Invalid passive port range: ${PASV_MIN_PORT}-${PASV_MAX_PORT} (min must be less than max)"
    fi
    
    if [ ${PASV_MIN_PORT} -lt 1024 ] || [ ${PASV_MAX_PORT} -gt 65535 ]; then
        error_exit "Passive ports must be between 1024 and 65535"
    fi
    
    verbose_log "Configuration validation passed"

    # Ensure vsftpd is installed
    if ! command_exists vsftpd; then
        log "vsftpd is not installed. Installing vsftpd..."
        if [ "${DRY_RUN}" == "no" ]; then
            if command_exists apt-get; then
                sudo apt-get update && sudo apt-get install -y vsftpd || error_exit "Failed to install vsftpd."
            elif command_exists yum; then
                sudo yum install -y vsftpd || error_exit "Failed to install vsftpd."
            else
                error_exit "Cannot find apt-get or yum. Please install vsftpd manually."
            fi
        else
            if command_exists apt-get; then
                log "DRY RUN: Would execute: sudo apt-get update && sudo apt-get install -y vsftpd"
            elif command_exists yum; then
                log "DRY RUN: Would execute: sudo yum install -y vsftpd"
            else
                log "DRY RUN: Cannot determine package manager. Would instruct manual vsftpd installation."
            fi
        fi
        log "vsftpd installed."
    else
        log "vsftpd is already installed. Skipping installation."
    fi

    create_user_and_dirs
    echo "" # Newline for readability

    setup_bind_mounts
    echo "" # Newline for readability

    configure_vsftpd
    echo "" # Newline for readability

    setup_firewall
    echo "" # Newline for readability

    log "5. Restarting vsftpd service..."
    execute_or_log "Restarting vsftpd service" sudo systemctl restart vsftpd || error_exit "Failed to restart vsftpd service. Check logs for errors (journalctl -u vsftpd)."
    execute_or_log "Enabling vsftpd service" sudo systemctl enable vsftpd || log "Warning: Failed to enable vsftpd service (autostart on boot)."
    log "vsftpd service restarted successfully."
    echo ""

    log "Setup complete! Please test your FTP connection for user '${FTP_USER}'."
    
    if [ "${GENERATE_PASSWORD}" == "yes" ]; then
        log "User password has been automatically generated and set (see above for password details)."
    elif [ "${SET_PASSWORD}" == "yes" ]; then
        log "User password has been set to your specified value."
    else
        log "Remember to set a password for the user if you haven't already: 'sudo passwd ${FTP_USER}'"
    fi
    
    # Final mount status check if verbose mode is enabled
    if [ "${VERBOSE_MODE}" == "yes" ] && [ "${DRY_RUN}" == "no" ]; then
        echo ""
        log "Final mount status verification:"
        local failed_final=0
        for mount_pair in "${BIND_MOUNTS[@]}"; do
            if ! check_mount_status "${mount_pair}"; then
                failed_final=$((failed_final + 1))
            fi
        done
        
        if [ ${failed_final} -eq 0 ]; then
            log "✓ All ${#BIND_MOUNTS[@]} mount(s) are operational!"
        else
            log "⚠ ${failed_final} out of ${#BIND_MOUNTS[@]} mount(s) may have issues. Use --check-mounts for detailed analysis."
        fi
    fi
    
    echo ""
    log "=== SETUP SUMMARY ==="
    log "User: ${FTP_USER}"
    log "Home: ${HOME_DIR}"
    log "Mounts configured: ${#BIND_MOUNTS[@]}"
    log "Firewall: ${FIREWALL_TYPE}"
    log "Passive ports: ${PASV_MIN_PORT}-${PASV_MAX_PORT}"
    echo ""
    
    log "If you encounter issues, check vsftpd logs: 'journalctl -u vsftpd' or 'tail -f /var/log/vsftpd.log'"
    log "Also check system authentication logs: 'tail -f /var/log/auth.log'"
    log "Use '--check-mounts' flag to verify mount status anytime"
}

# Execute the main function
main "$@"


set +euo pipefail