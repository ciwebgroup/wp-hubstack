#!/bin/bash

# Elementor Export to Google Drive Runner Script
# This script sets up the environment and runs the Python Elementor export script

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_SCRIPT="${SCRIPT_DIR}/elementor-export-to-drive.py"
REQUIREMENTS_FILE="${SCRIPT_DIR}/elementor-export-requirements.txt"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if Python packages are installed
check_dependencies() {
    print_info "Checking Python dependencies..."
    
    # Check if required packages are installed
    python3 -c "
import sys
try:
    from googleapiclient.discovery import build
    from googleapiclient.http import MediaFileUpload
    from google.oauth2.service_account import Credentials
    print('All required packages are installed')
except ImportError as e:
    print(f'Missing dependencies: {e}')
    sys.exit(1)
" 2>/dev/null || {
        print_warning "Required Python packages not found"
        print_info "Installing dependencies from ${REQUIREMENTS_FILE}..."
        pip3 install -r "${REQUIREMENTS_FILE}" || {
            print_error "Failed to install dependencies"
            print_info "Please run: pip3 install -r ${REQUIREMENTS_FILE}"
            exit 1
        }
    }
}

# Function to show usage information
show_usage() {
    echo "Usage: $0 --auth-json <path_to_credentials.json> --drive-folder-id <folder_id> [--site-container <container_name>]"
    echo ""
    echo "Options:"
    echo "  --auth-json         Path to Google Service Account JSON credentials file"
    echo "  --drive-folder-id   Google Drive folder ID where exports will be stored"
    echo "  --site-container    Process only the specified container (optional)"
    echo "  --help              Show this help message"
    echo ""
    echo "Examples:"
    echo "  # Process all _wp containers:"
    echo "  $0 --auth-json /path/to/service-account.json --drive-folder-id 1ABC123DEF456GHI789"
    echo ""
    echo "  # Process specific container:"
    echo "  $0 --auth-json /path/to/service-account.json --drive-folder-id 1ABC123DEF456GHI789 --site-container _wp_mysite_1"
    echo ""
    echo "Prerequisites:"
    echo "  1. Docker must be installed and running"
    echo "  2. WordPress containers with names starting with '_wp' must be running"
    echo "  3. Elementor plugin must be installed and active in the containers"
    echo "  4. Google Service Account JSON file with Drive API access"
    echo "  5. Target Google Drive folder ID (shared with the service account)"
}

# Parse command line arguments
AUTH_JSON=""
DRIVE_FOLDER_ID=""
SITE_CONTAINER=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --auth-json)
            AUTH_JSON="$2"
            shift 2
            ;;
        --drive-folder-id)
            DRIVE_FOLDER_ID="$2"
            shift 2
            ;;
        --site-container)
            SITE_CONTAINER="$2"
            shift 2
            ;;
        --help|-h)
            show_usage
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Validate required arguments
if [[ -z "$AUTH_JSON" || -z "$DRIVE_FOLDER_ID" ]]; then
    print_error "Missing required arguments"
    echo ""
    show_usage
    exit 1
fi

# Check if auth JSON file exists
if [[ ! -f "$AUTH_JSON" ]]; then
    print_error "Auth JSON file not found: $AUTH_JSON"
    exit 1
fi

# Check if Docker is available
if ! command -v docker &> /dev/null; then
    print_error "Docker is not installed or not in PATH"
    exit 1
fi

# Check if Docker daemon is running
if ! docker info &> /dev/null; then
    print_error "Docker daemon is not running"
    exit 1
fi

print_info "Starting Elementor Export to Google Drive process..."
print_info "Auth JSON: $AUTH_JSON"
print_info "Drive Folder ID: $DRIVE_FOLDER_ID"
if [[ -n "$SITE_CONTAINER" ]]; then
    print_info "Target Container: $SITE_CONTAINER"
fi

# Check dependencies
check_dependencies

# Run the Python script
print_info "Executing export script..."
if [[ -n "$SITE_CONTAINER" ]]; then
    python3 "${PYTHON_SCRIPT}" --auth-json "$AUTH_JSON" --drive-folder-id "$DRIVE_FOLDER_ID" --site-container "$SITE_CONTAINER"
else
    python3 "${PYTHON_SCRIPT}" --auth-json "$AUTH_JSON" --drive-folder-id "$DRIVE_FOLDER_ID"
fi

print_info "Export process completed!" 