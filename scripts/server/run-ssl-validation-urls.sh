#!/bin/bash

set -auo pipefail

# Parse command line arguments for SSL mode and dry-run options FIRST
SSL_MODE="full"  # Default mode
DRY_RUN_ARGS=""

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --mode)
            SSL_MODE="$2"
            shift
            ;;
        --dry-run)
            DRY_RUN_ARGS="--dry-run"
            # Check if next argument is a dry-run mode
            case "$2" in
                ""|--*) ;;  # No mode specified or next option
                *) DRY_RUN_ARGS="--dry-run $2"; shift ;;
            esac
            ;;
        --help)
            cat << EOF
Usage: $0 [--mode <ssl_mode>] [--dry-run [mode]] [--help]

This script runs the SSL mode update script for all discovered container URLs.

Optional Parameters:
  --mode <ssl_mode>     SSL/TLS encryption mode. Options:
                        - off: No encryption
                        - flexible: Cloudflare to visitor only
                        - full: End-to-end encryption (default)
                        - strict: End-to-end with certificate validation
  --dry-run [mode]      Pass dry-run mode to the SSL mode script.
                        Modes:
                        - full (default): Show what would be executed
                        - on-update: Execute GET but stop before PATCH
  --help                Display this help message and exit.

Examples:
  $0                           # Update all domains to 'full' SSL
  $0 --mode strict             # Update all domains to 'strict' SSL
  $0 --dry-run                 # Show what would be executed
  $0 --mode strict --dry-run   # Show what strict mode would do
EOF
            exit 0
            ;;
        *)
            echo "Error: Unknown parameter passed: $1"
            echo "Use --help for usage information."
            exit 1
            ;;
    esac
    shift
done

# Get all active container names (excluding traefik)
CONTAINERS=$(docker ps --format "{{.Names}}" | grep -v '^traefik$' || true)

if [ -z "$CONTAINERS" ]; then
    echo "No containers found (excluding traefik). Exiting."
    exit 0
fi

echo "Found containers to check:"
echo "$CONTAINERS"

# Extract URLs from container environment variables
URLS=()
for container in $CONTAINERS; do
    # Try to extract WP_HOME environment variable from container
    wp_home=$(docker inspect "$container" | jq -r '.[0].Config.Env[]? | select(startswith("WP_HOME="))' 2>/dev/null | sed 's/WP_HOME=//' || true)
    
    if [ -n "$wp_home" ]; then
        # Remove protocol (http:// or https://) to get just the domain
        domain=$(echo "$wp_home" | sed -e 's|^https\?://||' -e 's|/.*$||')
        URLS+=("$domain")
        echo "Found URL for $container: $domain"
    fi
done

if [ ${#URLS[@]} -eq 0 ]; then
    echo "No URLs found in container environment variables."
    exit 0
fi

# Verify that all URLs (without HTTPS or HTTP however) are valid

function validate_url() {
    local url="$1"
    # Remove quotes that might be present
    url=$(echo "$url" | tr -d '"')
    
    # Simple validation: must contain at least one dot and no spaces/invalid characters
    if [[ "$url" =~ ^[a-zA-Z0-9.-]+$ && "$url" =~ \. ]]; then
        return 0  # Valid domain
    else
        return 1  # Invalid domain
    fi
}

VALID_URLS=()

for url in "${URLS[@]}"; do
    if ! validate_url "$url"; then
        echo "Skipping invalid URL: $url"
    else
        VALID_URLS+=("$url")
    fi
done

# Filter out any URLS that match $IGNORE_PATTERN

IGNORE_PATTERN="ciwgserver"
FILTERED_URLS=()

for url in "${VALID_URLS[@]}"; do
    # Remove quotes from URL
    clean_url=$(echo "$url" | tr -d '"')
    if [[ ! "$clean_url" =~ $IGNORE_PATTERN ]]; then
        FILTERED_URLS+=("$clean_url")
    fi
done

# Strip www from each filtered URL
for i in "${!FILTERED_URLS[@]}"; do
    FILTERED_URLS[$i]=$(echo "${FILTERED_URLS[$i]}" | sed 's/^www\.//')
done

echo "Valid URLs after filtering: ${FILTERED_URLS[@]}"

# Create logs directory if it doesn't exist
mkdir -p "$HOME/logs"

echo "Running SSL mode update with mode: $SSL_MODE"
if [ -n "$DRY_RUN_ARGS" ]; then
    echo "Dry run mode enabled: $DRY_RUN_ARGS"
fi
echo "Processing ${#FILTERED_URLS[@]} URLs..."
echo

for url in "${FILTERED_URLS[@]}"; do
    echo "Processing: $url"
    
    # Build command with SSL mode and optional dry-run arguments
    cmd="/var/opt/scripts/switch-ssl-to-full.sh --url \"$url\" --mode \"$SSL_MODE\""
    if [ -n "$DRY_RUN_ARGS" ]; then
        cmd="$cmd $DRY_RUN_ARGS"
    fi
    
    echo "Executing: $cmd"
    
    # Execute the command and log output
    eval "$cmd" >> "$HOME/logs/ssl-mode-update-urls.log" 2>&1
    
    # Show the log output for this URL
    echo "--- Log output for $url ---"
    tail -n 20 "$HOME/logs/ssl-mode-update-urls.log"
    echo "--- End log output ---"
    echo
done

echo "All SSL mode updates completed. Full log available at: $HOME/logs/ssl-mode-update-urls.log"

set +auo pipefail