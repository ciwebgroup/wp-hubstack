#!/bin/bash

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

# --- Script Functions ---

# Function to display usage information
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Automates vsftpd setup with chroot and rbind mounts."
    echo ""
    echo "Options:"
    echo "  -u, --user <username>          Set the FTP system username (default: ${FTP_USER})"
    echo "  -b, --bind-mounts <'src::dest src2::dest2'> "
    echo "                                 Set bind mounts (default: ${BIND_MOUNTS[@]})"
    echo "                                 Separate multiple mounts with spaces, e.g., 'src1::dest1 src2::dest2'"
    echo "  -w, --writable-chroot          Enable 'allow_writeable_chroot=YES' (less secure)"
    echo "  -f, --firewall <type>          Set firewall type (ufw, firewalld, none, default: ${FIREWALL_TYPE})"
    echo "  -p, --pasv-ports <min:max>     Set passive port range (default: ${PASV_MIN_PORT}:${PASV_MAX_PORT})"
    echo "  --add-mounts-only              Only add new mounts to existing user (skip full setup)"
    echo "  --generate-password            Generate and set a temporary password for the user"
    echo "  --dry-run                      Simulate the execution without making any changes"
    echo "  -h, --help                     Display this help message"
    echo ""
    echo "Examples:"
    echo "  # Full setup for new user:"
    echo "  sudo $0 -u myftpuser -b '/var/web::webroot /data::shared' -f ufw --dry-run"
    echo ""
    echo "  # Full setup with temporary password generation:"
    echo "  sudo $0 -u myftpuser -b '/var/web::webroot' --generate-password"
    echo ""
    echo "  # Add new mounts to existing user:"
    echo "  sudo $0 -u myftpuser -b '/new/path::newdir /another/path::anotherdir' --add-mounts-only"
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
                # Clear existing and parse new bind mounts
                BIND_MOUNTS=()
                IFS=' ' read -r -a mounts_array <<< "$2"
                for mount_pair in "${mounts_array[@]}"; do
                    BIND_MOUNTS+=("$mount_pair")
                done
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

    # Handle password generation if requested
    if [ "${GENERATE_PASSWORD}" == "yes" ]; then
        if [ "${USER_CREATED}" == "yes" ] || [ "${ADD_MOUNTS_ONLY}" != "yes" ]; then
            log "Generating temporary password for user '${FTP_USER}'..."
            TEMP_PASSWORD=$(generate_temp_password)
            
            if [ -n "${TEMP_PASSWORD}" ]; then
                execute_or_log "Setting temporary password" set_user_password "${FTP_USER}" "${TEMP_PASSWORD}" || error_exit "Failed to set password for user ${FTP_USER}."
                
                if [ "${DRY_RUN}" == "no" ]; then
                    log "SUCCESS: Temporary password set for user '${FTP_USER}'"
                    log "============================================"
                    log "TEMPORARY PASSWORD: ${TEMP_PASSWORD}"
                    log "============================================"
                    log "IMPORTANT: Please save this password securely and consider changing it after first login!"
                else
                    log "DRY RUN: Would generate and set temporary password for user '${FTP_USER}'"
                fi
            else
                error_exit "Failed to generate temporary password."
            fi
        else
            log "Password generation requested but user already exists and add-mounts-only mode is active. Skipping password generation."
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
    execute_or_log "Setting permissions of ${UPLOAD_DIR}" sudo chmod 775 "${UPLOAD_DIR}" || error_exit "Failed to set permissions of ${UPLOAD_DIR}."
    log "Created writable uploads directory: ${UPLOAD_DIR}."

    # Create destination directories for bind mounts and set ownership
    for mount_pair in "${BIND_MOUNTS[@]}"; do
        # Extract destination path - Assuming format "SOURCE::DEST"
        # Using string manipulation to get the part after the first "::"
        DEST_PATH="${mount_pair##*::}"
        DEST_DIR_IN_CHROOT="${HOME_DIR}/${DEST_PATH}"

        execute_or_log "Creating bind-mount destination directory ${DEST_DIR_IN_CHROOT}" sudo mkdir -p "${DEST_DIR_IN_CHROOT}" || error_exit "Failed to create destination directory ${DEST_DIR_IN_CHROOT}."
        execute_or_log "Setting ownership of ${DEST_DIR_IN_CHROOT}" sudo chown "${FTP_USER}:${FTP_USER}" "${DEST_DIR_IN_CHROOT}" || error_exit "Failed to set ownership of ${DEST_DIR_IN_CHROOT}."
        execute_or_log "Setting permissions of ${DEST_DIR_IN_CHROOT}" sudo chmod 755 "${DEST_DIR_IN_CHROOT}" || error_exit "Failed to set permissions of ${DEST_DIR_IN_CHROOT}."
        log "Created bind-mount destination directory: ${DEST_DIR_IN_CHROOT}."
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
        DEST_PATH="${mount_pair##*::}"
        DEST_DIR_IN_CHROOT="${HOME_DIR}/${DEST_PATH}"

        # Check if mount already exists
        FSTAB_ENTRY="${mount_pair%%::*} ${DEST_DIR_IN_CHROOT} none rw,rbind 0 0"
        if grep -Fxq "${FSTAB_ENTRY}" /etc/fstab; then
            log "Mount '${mount_pair}' already exists in fstab. Skipping."
            continue
        fi

        if mountpoint -q "${DEST_DIR_IN_CHROOT}"; then
            log "Mount point '${DEST_DIR_IN_CHROOT}' is already mounted. Skipping."
            continue
        fi

        execute_or_log "Creating bind-mount destination directory ${DEST_DIR_IN_CHROOT}" sudo mkdir -p "${DEST_DIR_IN_CHROOT}" || error_exit "Failed to create destination directory ${DEST_DIR_IN_CHROOT}."
        execute_or_log "Setting ownership of ${DEST_DIR_IN_CHROOT}" sudo chown "${FTP_USER}:${FTP_USER}" "${DEST_DIR_IN_CHROOT}" || error_exit "Failed to set ownership of ${DEST_DIR_IN_CHROOT}."
        execute_or_log "Setting permissions of ${DEST_DIR_IN_CHROOT}" sudo chmod 755 "${DEST_DIR_IN_CHROOT}" || error_exit "Failed to set permissions of ${DEST_DIR_IN_CHROOT}."
        log "Created bind-mount destination directory: ${DEST_DIR_IN_CHROOT}."
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

        if mountpoint -q "${DEST_DIR_IN_CHROOT}"; then
            log "Mount point '${DEST_DIR_IN_CHROOT}' is already mounted. Skipping setup."
            continue
        fi

        # Ensure source directory exists and has appropriate permissions
        execute_or_log "Creating source directory ${SOURCE_PATH}" sudo mkdir -p "${SOURCE_PATH}" || error_exit "Failed to create source directory ${SOURCE_PATH}."
        execute_or_log "Setting ownership of source directory ${SOURCE_PATH}" sudo chown -R "${FTP_USER}:${FTP_USER}" "${SOURCE_PATH}" || log "Warning: Failed to set ownership of ${SOURCE_PATH}. Check manually."
        execute_or_log "Setting permissions of source directory ${SOURCE_PATH}" sudo chmod -R 775 "${SOURCE_PATH}" || log "Warning: Failed to set permissions of ${SOURCE_PATH}. Check manually."
        log "Ensured source directory '${SOURCE_PATH}' exists and permissions set."

        # Perform the bind mount
        execute_or_log "Bind mounting ${SOURCE_PATH} to ${DEST_DIR_IN_CHROOT}" sudo mount --rbind "${SOURCE_PATH}" "${DEST_DIR_IN_CHROOT}" || error_exit "Failed to bind mount ${SOURCE_PATH} to ${DEST_DIR_IN_CHROOT}."
        log "Bind mounted '${SOURCE_PATH}' to '${DEST_DIR_IN_CHROOT}'."

        # Add to /etc/fstab for persistence
        execute_or_log "Adding fstab entry for persistence" echo "${FSTAB_ENTRY}" | sudo tee -a /etc/fstab > /dev/null || error_exit "Failed to add fstab entry."
        log "Added fstab entry for persistence: ${FSTAB_ENTRY}."
    done

    log "Successfully added ${#BIND_MOUNTS[@]} new mount(s) to user '${FTP_USER}'."
}

# Function to set up source directories and bind mounts
setup_bind_mounts() {
    log "2. Setting up source directories and bind mounts..."

    for mount_pair in "${BIND_MOUNTS[@]}"; do
        # Extract source and destination paths
        SOURCE_PATH="${mount_pair%%::*}" # Get part before "::"
        DEST_PATH="${mount_pair##*::}"   # Get part after "::"
        DEST_DIR_IN_CHROOT="${HOME_DIR}/${DEST_PATH}"

        # Ensure source directory exists and has appropriate permissions
        execute_or_log "Creating source directory ${SOURCE_PATH}" sudo mkdir -p "${SOURCE_PATH}" || error_exit "Failed to create source directory ${SOURCE_PATH}."
        # Note: Permissions on source dir are crucial for actual file access
        # Defaulting to ftpuser:ftpuser and 775, but adjust as needed for your specific use case
        execute_or_log "Setting ownership of source directory ${SOURCE_PATH}" sudo chown -R "${FTP_USER}:${FTP_USER}" "${SOURCE_PATH}" || log "Warning: Failed to set ownership of ${SOURCE_PATH}. Check manually."
        execute_or_log "Setting permissions of source directory ${SOURCE_PATH}" sudo chmod -R 775 "${SOURCE_PATH}" || log "Warning: Failed to set permissions of ${SOURCE_PATH}. Check manually."
        log "Ensured source directory '${SOURCE_PATH}' exists and permissions set (may need manual adjustment)."

        # Perform the bind mount
        if ! mountpoint -q "${DEST_DIR_IN_CHROOT}"; then
            execute_or_log "Bind mounting ${SOURCE_PATH} to ${DEST_DIR_IN_CHROOT}" sudo mount --rbind "${SOURCE_PATH}" "${DEST_DIR_IN_CHROOT}" || error_exit "Failed to bind mount ${SOURCE_PATH} to ${DEST_DIR_IN_CHROOT}."
            log "Bind mounted '${SOURCE_PATH}' to '${DEST_DIR_IN_CHROOT}'."
        else
            log "Mount point '${DEST_DIR_IN_CHROOT}' is already mounted. Skipping."
        fi

        # Add to /etc/fstab for persistence if not already there
        FSTAB_ENTRY="${SOURCE_PATH} ${DEST_DIR_IN_CHROOT} none rw,rbind 0 0"
        if ! grep -Fxq "${FSTAB_ENTRY}" /etc/fstab; then
            execute_or_log "Adding fstab entry for persistence" echo "${FSTAB_ENTRY}" | sudo tee -a /etc/fstab > /dev/null || error_exit "Failed to add fstab entry."
            log "Added fstab entry for persistence: ${FSTAB_ENTRY}."
        else
            log "Fstab entry already exists for '${SOURCE_PATH}' to '${DEST_DIR_IN_CHROOT}'. Skipping."
        fi
    done
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
    sudo sed -i "/^#*${key}=/d" "${config_file}"
    
    # Add the new configuration
    echo "${key}=${value}" | sudo tee -a "${config_file}" > /dev/null
    log "Added/updated configuration: ${key}=${value}"
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
    # Check for root privileges
    if [[ $EUID -ne 0 ]]; then
        error_exit "This script must be run as root. Please use sudo."
    fi

    # Parse command-line arguments
    parse_arguments "$@"

    # Handle add-mounts-only mode
    if [ "${ADD_MOUNTS_ONLY}" == "yes" ]; then
        log "Add-mounts-only mode enabled for user: '${FTP_USER}'"
        log "Home directory: '${HOME_DIR}'"
        log "New bind mounts to add: ${BIND_MOUNTS[@]}"
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
    log "Dry run enabled: ${DRY_RUN}"
    echo ""

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
    else
        log "Remember to set a password for the user if you haven't already: 'sudo passwd ${FTP_USER}'"
    fi
    
    log "If you encounter issues, check vsftpd logs: 'journalctl -u vsftpd' or 'tail -f /var/log/vsftpd.log'"
    log "Also check system authentication logs: 'tail -f /var/log/auth.log'"
}

# Execute the main function
main "$@"

