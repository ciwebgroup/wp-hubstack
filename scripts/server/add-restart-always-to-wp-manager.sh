#!/bin/bash

# Script to safely add restart: always to docker-compose.yml using yq
# Usage: ./add-restart-policy.sh [--dry-run]

set -euo pipefail

# Configuration
DOCKER_COMPOSE_FILE="/var/opt/wordpress-manager/docker-compose.yml"
BACKUP_SUFFIX=".backup.$(date +%Y%m%d_%H%M%S)"
DRY_RUN="no"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    local color=$1
    local message=$2
    local prefix=""
    
    if [ "${DRY_RUN}" == "yes" ]; then
        prefix="[DRY RUN] "
    fi
    
    echo -e "${color}[$(date +'%Y-%m-%d %H:%M:%S')] ${prefix}${message}${NC}"
}

# Function to display usage information
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --dry-run    Show what would be done without making changes"
    echo "  -h, --help   Display this help message"
    echo ""
    echo "Examples:"
    echo "  $0                    # Apply changes and restart services"
    echo "  $0 --dry-run          # Show what would be done without making changes"
    echo ""
    echo "This script will:"
    echo "  1. Add 'restart: always' to the wordpress-manager service"
    echo "  2. Validate the docker-compose.yml configuration"
    echo "  3. Restart the services to apply changes"
    exit 1
}

# Function to parse command line arguments
parse_arguments() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN="yes"
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                print_status $RED "Unknown option: $1"
                usage
                ;;
        esac
    done
}

# Function to check if yq is installed
check_yq() {
    if ! command -v yq &> /dev/null; then
        print_status $RED "ERROR: yq is not installed or not in PATH"
        echo "Please install yq first:"
        echo "  - Download from: https://github.com/mikefarah/yq/releases"
        echo "  - Or install via package manager:"
        echo "    Ubuntu/Debian: sudo apt install yq"
        echo "    CentOS/RHEL: sudo yum install yq"
        echo "    macOS: brew install yq"
        exit 1
    fi
    
    # Check yq version (we need v4+ for the syntax we'll use)
    local yq_version=$(yq --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
    if [[ -z "$yq_version" ]]; then
        print_status $YELLOW "WARNING: Could not determine yq version. Proceeding anyway..."
    else
        print_status $GREEN "Found yq version: $yq_version"
    fi
}

# Function to check if docker and docker compose are available
check_docker() {
    if ! command -v docker &> /dev/null; then
        print_status $RED "ERROR: docker is not installed or not in PATH"
        exit 1
    fi
    
    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        print_status $RED "ERROR: docker-compose is not installed or not in PATH"
        exit 1
    fi
    
    print_status $GREEN "Docker and Docker Compose are available"
}

# Function to validate docker-compose.yml file
validate_file() {
    if [[ ! -f "$DOCKER_COMPOSE_FILE" ]]; then
        print_status $RED "ERROR: Docker Compose file not found: $DOCKER_COMPOSE_FILE"
        exit 1
    fi
    
    if [[ ! -r "$DOCKER_COMPOSE_FILE" ]]; then
        print_status $RED "ERROR: Cannot read Docker Compose file: $DOCKER_COMPOSE_FILE"
        exit 1
    fi
    
    if [[ "${DRY_RUN}" == "no" ]] && [[ ! -w "$DOCKER_COMPOSE_FILE" ]]; then
        print_status $RED "ERROR: Cannot write to Docker Compose file: $DOCKER_COMPOSE_FILE"
        exit 1
    fi
    
    print_status $GREEN "Docker Compose file found and accessible: $DOCKER_COMPOSE_FILE"
}

# Function to create backup
create_backup() {
    if [ "${DRY_RUN}" == "yes" ]; then
        local backup_file="${DOCKER_COMPOSE_FILE}${BACKUP_SUFFIX}"
        print_status $CYAN "Would create backup: $backup_file"
        echo "$backup_file"  # Return backup filename
        return 0
    fi
    
    local backup_file="${DOCKER_COMPOSE_FILE}${BACKUP_SUFFIX}"
    
    if cp "$DOCKER_COMPOSE_FILE" "$backup_file"; then
        print_status $GREEN "Backup created: $backup_file"
        echo "$backup_file"  # Return backup filename
    else
        print_status $RED "ERROR: Failed to create backup"
        exit 1
    fi
}

# Function to check if restart policy already exists
check_existing_restart() {
    local restart_value=$(yq eval '.services.wordpress-manager.restart' "$DOCKER_COMPOSE_FILE" 2>/dev/null || echo "null")
    
    if [[ "$restart_value" != "null" ]]; then
        print_status $YELLOW "Restart policy already exists: $restart_value"
        return 0
    else
        print_status $BLUE "No restart policy found, will add 'always'"
        return 1
    fi
}

# Function to add restart policy
add_restart_policy() {
    print_status $BLUE "Adding restart: always to wordpress-manager service..."
    
    if [ "${DRY_RUN}" == "yes" ]; then
        print_status $CYAN "Would execute: yq eval '.services.wordpress-manager.restart = \"always\"' -i \"$DOCKER_COMPOSE_FILE\""
        
        # Show what the change would look like
        print_status $CYAN "Preview of the change:"
        echo "--- Current configuration ---"
        yq eval '.services.wordpress-manager' "$DOCKER_COMPOSE_FILE" 2>/dev/null || echo "Service not found"
        echo ""
        echo "--- After adding restart: always ---"
        yq eval '.services.wordpress-manager.restart = "always" | .services.wordpress-manager' "$DOCKER_COMPOSE_FILE" 2>/dev/null || echo "Service not found"
        return 0
    fi
    
    # Use yq to add the restart policy
    if yq eval '.services.wordpress-manager.restart = "always"' -i "$DOCKER_COMPOSE_FILE"; then
        print_status $GREEN "Successfully added restart: always"
        return 0
    else
        print_status $RED "ERROR: Failed to add restart policy"
        return 1
    fi
}

# Function to validate the modified file
validate_modified_file() {
    print_status $BLUE "Validating modified docker-compose.yml..."
    
    if [ "${DRY_RUN}" == "yes" ]; then
        print_status $CYAN "Would validate YAML structure and restart policy"
        return 0
    fi
    
    # Check if yq can read the file
    if ! yq eval '.' "$DOCKER_COMPOSE_FILE" >/dev/null 2>&1; then
        print_status $RED "ERROR: Modified file is not valid YAML"
        return 1
    fi
    
    # Verify restart policy was added correctly
    local restart_value=$(yq eval '.services.wordpress-manager.restart' "$DOCKER_COMPOSE_FILE" 2>/dev/null || echo "null")
    if [[ "$restart_value" == "always" ]]; then
        print_status $GREEN "✓ Restart policy verified: $restart_value"
        return 0
    else
        print_status $RED "ERROR: Restart policy not found or incorrect: $restart_value"
        return 1
    fi
}

# Function to test docker compose configuration
test_docker_compose_config() {
    print_status $BLUE "Testing Docker Compose configuration..."
    
    if [ "${DRY_RUN}" == "yes" ]; then
        print_status $CYAN "Would execute: docker compose config -q"
        print_status $CYAN "Would change to directory: $(dirname "$DOCKER_COMPOSE_FILE")"
        return 0
    fi
    
    # Change to the directory containing the docker-compose.yml file
    local compose_dir=$(dirname "$DOCKER_COMPOSE_FILE")
    cd "$compose_dir" || {
        print_status $RED "ERROR: Cannot change to directory: $compose_dir"
        return 1
    }
    
    # Test configuration using docker compose config
    local config_output
    local config_exit_code
    
    if command -v docker-compose &> /dev/null; then
        # Use docker-compose (v1)
        config_output=$(docker-compose config -q 2>&1)
        config_exit_code=$?
    else
        # Use docker compose (v2)
        config_output=$(docker compose config -q 2>&1)
        config_exit_code=$?
    fi
    
    if [[ $config_exit_code -eq 0 ]]; then
        print_status $GREEN "✓ Docker Compose configuration is valid"
        return 0
    else
        print_status $RED "ERROR: Docker Compose configuration validation failed:"
        echo "$config_output"
        return 1
    fi
}

# Function to restart docker compose services
restart_docker_compose_services() {
    print_status $BLUE "Restarting Docker Compose services..."
    
    if [ "${DRY_RUN}" == "yes" ]; then
        print_status $CYAN "Would execute: docker compose down && docker compose up -d"
        print_status $CYAN "Would change to directory: $(dirname "$DOCKER_COMPOSE_FILE")"
        return 0
    fi
    
    # Change to the directory containing the docker-compose.yml file
    local compose_dir=$(dirname "$DOCKER_COMPOSE_FILE")
    cd "$compose_dir" || {
        print_status $RED "ERROR: Cannot change to directory: $compose_dir"
        return 1
    }
    
    # Stop services
    print_status $BLUE "Stopping services..."
    if command -v docker-compose &> /dev/null; then
        # Use docker-compose (v1)
        if ! docker-compose down; then
            print_status $RED "ERROR: Failed to stop services with docker-compose down"
            return 1
        fi
    else
        # Use docker compose (v2)
        if ! docker compose down; then
            print_status $RED "ERROR: Failed to stop services with docker compose down"
            return 1
        fi
    fi
    
    print_status $GREEN "✓ Services stopped successfully"
    
    # Start services in detached mode
    print_status $BLUE "Starting services in detached mode..."
    if command -v docker-compose &> /dev/null; then
        # Use docker-compose (v1)
        if ! docker-compose up -d; then
            print_status $RED "ERROR: Failed to start services with docker-compose up -d"
            return 1
        fi
    else
        # Use docker compose (v2)
        if ! docker compose up -d; then
            print_status $RED "ERROR: Failed to start services with docker compose up -d"
            return 1
        fi
    fi
    
    print_status $GREEN "✓ Services started successfully in detached mode"
    return 0
}

# Function to show diff
show_diff() {
    local backup_file="$1"
    
    if [ "${DRY_RUN}" == "yes" ]; then
        print_status $CYAN "Would show diff between backup and modified file"
        return 0
    fi
    
    if command -v diff &> /dev/null; then
        print_status $BLUE "Changes made:"
        echo "--- Original file"
        echo "+++ Modified file"
        diff "$backup_file" "$DOCKER_COMPOSE_FILE" || true
        echo ""
    fi
}

# Function to restore backup on error
restore_backup() {
    local backup_file="$1"
    local error_msg="$2"
    
    if [ "${DRY_RUN}" == "yes" ]; then
        print_status $CYAN "Would restore from backup: $backup_file"
        print_status $CYAN "Error that would trigger restore: $error_msg"
        return 0
    fi
    
    print_status $RED "ERROR: $error_msg"
    print_status $YELLOW "Restoring from backup: $backup_file"
    
    if cp "$backup_file" "$DOCKER_COMPOSE_FILE"; then
        print_status $GREEN "Backup restored successfully"
    else
        print_status $RED "CRITICAL ERROR: Failed to restore backup!"
        print_status $RED "Original file is at: $backup_file"
        exit 1
    fi
}

# Main function
main() {
    # Parse command line arguments first
    parse_arguments "$@"
    
    if [ "${DRY_RUN}" == "yes" ]; then
        print_status $CYAN "=== DRY RUN MODE ==="
        print_status $CYAN "No actual changes will be made"
        echo ""
    fi
    
    print_status $BLUE "Starting docker-compose.yml restart policy addition"
    print_status $BLUE "Target file: $DOCKER_COMPOSE_FILE"
    echo ""
    
    # Check prerequisites
    check_yq
    check_docker
    validate_file
    
    # Check if restart policy already exists
    if check_existing_restart; then
        print_status $YELLOW "Restart policy already exists. No changes needed."
        exit 0
    fi
    
    # Create backup
    local backup_file
    backup_file=$(create_backup)
    echo ""
    
    # Add restart policy
    if ! add_restart_policy; then
        restore_backup "$backup_file" "Failed to add restart policy"
        exit 1
    fi
    
    # Validate the modified file
    if ! validate_modified_file; then
        restore_backup "$backup_file" "Modified file validation failed"
        exit 1
    fi
    
    # Test Docker Compose configuration
    if ! test_docker_compose_config; then
        restore_backup "$backup_file" "Docker Compose configuration validation failed"
        exit 1
    fi
    
    echo ""
    print_status $GREEN "✓ Successfully added restart: always to docker-compose.yml"
    
    # Show diff
    show_diff "$backup_file"
    
    # Restart services
    if ! restart_docker_compose_services; then
        if [ "${DRY_RUN}" == "no" ]; then
            print_status $YELLOW "WARNING: Failed to restart services. You may need to restart them manually."
            print_status $BLUE "You can restart services manually with:"
            echo "  cd $(dirname "$DOCKER_COMPOSE_FILE")"
            echo "  docker compose down && docker compose up -d"
            echo ""
        fi
    else
        if [ "${DRY_RUN}" == "no" ]; then
            print_status $GREEN "✓ Services restarted successfully with new restart policy"
        fi
    fi
    
    if [ "${DRY_RUN}" == "no" ]; then
        print_status $GREEN "Backup file: $backup_file"
    else
        print_status $CYAN "=== DRY RUN COMPLETED ==="
        print_status $CYAN "No changes were made. Run without --dry-run to apply changes."
    fi
}

# Handle script interruption
trap 'print_status $RED "Script interrupted. Exiting..."; exit 1' INT TERM

# Execute main function
main "$@"