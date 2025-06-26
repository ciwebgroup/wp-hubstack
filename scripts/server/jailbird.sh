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
    echo "  --dry-run                      Simulate the execution without making any changes"
    echo "  -h, --help                     Display this help message"
    echo ""
    echo "Example:"
    echo "  sudo $0 -u myftpuser -b '/var/web::webroot /data::shared' -f ufw --dry-run"
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
    if ! id "${FTP_USER}" &>/dev/null; then
        execute_or_log "Creating user ${FTP_USER}" sudo adduser --disabled-password --gecos "" "${FTP_USER}" || error_exit "Failed to add user ${FTP_USER}."
        log "User '${FTP_USER}' created."
    else
        log "User '${FTP_USER}' already exists. Skipping user creation."
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

    # Update vsftpd.conf (using sed for idempotent operations)
    log "Removing potentially conflicting lines from ${VSFTPD_CONF}."
    execute_or_log "Removing listen" sudo sed -i '/^listen=/d' "${VSFTPD_CONF}"
    execute_or_log "Removing listen_ipv6" sudo sed -i '/^listen_ipv6=/d' "${VSFTPD_CONF}"
    execute_or_log "Removing anonymous_enable" sudo sed -i '/^anonymous_enable=/d' "${VSFTPD_CONF}"
    execute_or_log "Removing local_enable" sudo sed -i '/^local_enable=/d' "${VSFTPD_CONF}"
    execute_or_log "Removing write_enable" sudo sed -i '/^write_enable=/d' "${VSFTPD_CONF}"
    execute_or_log "Removing chroot_local_user" sudo sed -i '/^chroot_local_user=/d' "${VSFTPD_CONF}"
    execute_or_log "Removing allow_writeable_chroot" sudo sed -i '/^allow_writeable_chroot=/d' "${VSFTPD_CONF}"
    execute_or_log "Removing pasv_enable" sudo sed -i '/^pasv_enable=/d' "${VSFTPD_CONF}"
    execute_or_log "Removing pasv_min_port" sudo sed -i '/^pasv_min_port=/d' "${VSFTPD_CONF}"
    execute_or_log "Removing pasv_max_port" sudo sed -i '/^pasv_max_port=/d' "${VSFTPD_CONF}"
    execute_or_log "Removing xferlog_enable" sudo sed -i '/^xferlog_enable=/d' "${VSFTPD_CONF}"
    execute_or_log "Removing xferlog_file" sudo sed -i '/^xferlog_file=/d' "${VSFTPD_CONF}"
    execute_or_log "Removing xferlog_std_format" sudo sed -i '/^xferlog_std_format=/d' "${VSFTPD_CONF}"

    log "Adding/appending required settings to ${VSFTPD_CONF}."
    VSFTPD_SETTINGS=$(cat <<EOF
listen=NO
listen_ipv6=YES
anonymous_enable=NO
local_enable=YES
write_enable=YES
chroot_local_user=YES
allow_writeable_chroot=${ALLOW_WRITEABLE_CHROOT}
pasv_enable=YES
pasv_min_port=${PASV_MIN_PORT}
pasv_max_port=${PASV_MAX_PORT}
xferlog_enable=YES
xferlog_file=/var/log/vsftpd.log
xferlog_std_format=YES
EOF
)
    execute_or_log "Appending new vsftpd configuration" echo "${VSFTPD_SETTINGS}" | sudo tee -a "${VSFTPD_CONF}" > /dev/null || error_exit "Failed to write vsftpd.conf settings."

    log "Updated ${VSFTPD_CONF} with chroot, passive mode, and logging settings."
}

# Function to configure firewall rules
setup_firewall() {
    log "4. Configuring firewall (${FIREWALL_TYPE})..."

    if [ "${FIREWAL_TYPE}" == "ufw" ]; then
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
    log "Remember to set a password for the user if you haven't already: 'sudo passwd ${FTP_USER}'"
    log "If you encounter issues, check vsftpd logs: 'journalctl -u vsftpd' or 'tail -f /var/log/vsftpd.log'"
    log "Also check system authentication logs: 'tail -f /var/log/auth.log'"
}

# Execute the main function
main "$@"

