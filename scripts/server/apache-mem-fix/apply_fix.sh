#!/bin/bash
set -eauo pipefail

# Configuration
SOURCE_CONF_DIR="$(dirname "$(realpath "$0")")"
CONF_FILE="mpm_prefork.conf"
PHP_FPM_CONF="php-fpm-pool.conf"
PHP_LIMITS_INI="php-limits.ini"
SEARCH_DIR="/var/opt/sites"

# Default flags
DRY_RUN=false
RESTART=false
OVERWRITE=false
TIER=""
APPLY_PHP_FPM=false
APPLY_PHP_LIMITS=false
INCLUDE_PATTERN=""
EXCLUDE_PATTERN=""

# Help function
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Apply Apache MPM Prefork memory configuration to WordPress Docker containers.

OPTIONS:
    --include PATTERN    Only process sites matching PATTERN (comma-separated)
                        Example: --include "example.com,test.com"
    
    --exclude PATTERN    Skip sites matching PATTERN (comma-separated)
                        Example: --exclude "staging,dev"
    
    --dry-run           Preview changes without applying them
    
    --restart           Restart containers after applying changes
                        (runs: docker compose down && docker compose up -d)
    
    --php-fpm           Apply PHP-FPM pool configuration
                        (mounts: php-fpm-pool.conf -> /usr/local/etc/php-fpm.d/www.conf)
    
    --php-limits        Apply PHP execution limits configuration
                        (mounts: php-limits.ini -> /usr/local/etc/php/conf.d/99-limits.ini)
    
    --overwrite         Overwrite existing configurations
                        (by default, skips sites that already have configs)
    
    --tier TIER         Use tiered configuration (1, 2, or 3)
                        Tier 1: High-traffic (2-3 sites/server, 15 workers, 512M)
                        Tier 2: Medium-traffic (5-7 sites/server, 10 workers, 384M)
                        Tier 3: Low-traffic (10-20 sites/server, 5 workers, 256M)
                        (automatically enables --php-fpm and --php-limits)
    
    --help              Show this help message

DESCRIPTION:
    This script searches for WordPress containers (with names starting with 'wp_')
    in $SEARCH_DIR and applies memory and PHP optimizations by:
    
    1. Backing up the docker-compose.yml file
    2. Copying configuration files to the site directory
    3. Adding volume mounts to the WordPress service
    
    The script is idempotent and will skip sites that already have the configuration.
    
    Configuration files applied:
    - mpm_prefork.conf: Apache MPM Prefork memory limits (always)
    - php-fpm-pool.conf: PHP-FPM process pool settings (--php-fpm)
    - php-limits.ini: PHP execution time and memory limits (--php-limits)

EXAMPLES:
    # Preview changes for all sites
    $(basename "$0") --dry-run
    
    # Apply fix to specific sites only
    $(basename "$0") --include "example.com,mysite.com"
    
    # Apply fix to all sites except staging
    $(basename "$0") --exclude "staging,dev"
    
    # Preview changes for production sites only
    $(basename "$0") --dry-run --exclude "staging,dev,test"
    
    # Apply fix and restart containers
    $(basename "$0") --restart --include "example.com"
    
    # Apply all configurations with PHP optimizations
    $(basename "$0") --php-fpm --php-limits --restart
    
    # Overwrite existing configurations (update to new tier)
    $(basename "$0") --overwrite --php-fpm --php-limits --restart
    
    # Deploy Tier 2 configuration to specific sites
    $(basename "$0") --tier 2 --include "example.com,mysite.com" --restart
    
    # Deploy Tier 3 to all low-traffic sites
    $(basename "$0") --tier 3 --exclude "bigstore.com" --restart

EOF
    exit 0
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --restart)
            RESTART=true
            shift
            ;;
        --php-fpm)
            APPLY_PHP_FPM=true
            shift
            ;;
        --php-limits)
            APPLY_PHP_LIMITS=true
            shift
            ;;
        --overwrite)
            OVERWRITE=true
            shift
            ;;
        --tier)
            TIER="$2"
            shift 2
            ;;
        --include)
            INCLUDE_PATTERN="$2"
            shift 2
            ;;
        --exclude)
            EXCLUDE_PATTERN="$2"
            shift 2
            ;;
        --help|-h)
            show_help
            ;;
        *)
            echo "Error: Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Handle tier configuration
if [[ -n "$TIER" ]]; then
    # Validate tier
    if [[ ! "$TIER" =~ ^[123]$ ]]; then
        echo "Error: Invalid tier '$TIER'. Must be 1, 2, or 3"
        exit 1
    fi
    
    # Switch to tier-specific configuration files
    CONF_FILE="mpm_prefork.conf.tier${TIER}"
    PHP_FPM_CONF="php-fpm-pool.conf.tier${TIER}"
    PHP_LIMITS_INI="php-limits.ini.tier${TIER}"
    
    # Verify tier config files exist
    for file in "$CONF_FILE" "$PHP_FPM_CONF" "$PHP_LIMITS_INI"; do
        if [[ ! -f "$SOURCE_CONF_DIR/$file" ]]; then
            echo "Error: Tier configuration file not found: $file"
            exit 1
        fi
    done
    
    # Automatically enable PHP configurations for tiered deployments
    APPLY_PHP_FPM=true
    APPLY_PHP_LIMITS=true
    
    # Display tier info
    echo "=========================================="
    echo "Tiered Configuration Deployment"
    echo "=========================================="
    echo ""
    echo "Tier: $TIER"
    case $TIER in
        1)
            echo "  Type: High-Traffic Sites"
            echo "  Workers: 15 max"
            echo "  Memory: 512M per process"
            echo "  Capacity: 2-3 sites per 16GB server"
            ;;
        2)
            echo "  Type: Medium-Traffic Sites"
            echo "  Workers: 10 max"
            echo "  Memory: 384M per process"
            echo "  Capacity: 5-7 sites per 16GB server"
            ;;
        3)
            echo "  Type: Low-Traffic Sites"
            echo "  Workers: 5 max"
            echo "  Memory: 256M per process"
            echo "  Capacity: 10-20 sites per 16GB server"
            ;;
    esac
    echo ""
fi

# Check if yq is installed
if ! command -v yq &> /dev/null; then
    echo "Error: yq is not installed."
    exit 1
fi

# Function to check if a path should be included
should_process() {
    local path="$1"
    local site_name=$(basename "$path")
    
    # Check exclude pattern first
    if [ -n "$EXCLUDE_PATTERN" ]; then
        IFS=',' read -ra EXCLUDE_ARRAY <<< "$EXCLUDE_PATTERN"
        for pattern in "${EXCLUDE_ARRAY[@]}"; do
            pattern=$(echo "$pattern" | xargs) # trim whitespace
            if [[ "$site_name" == *"$pattern"* ]] || [[ "$path" == *"$pattern"* ]]; then
                return 1 # false - should not process
            fi
        done
    fi
    
    # Check include pattern
    if [ -n "$INCLUDE_PATTERN" ]; then
        IFS=',' read -ra INCLUDE_ARRAY <<< "$INCLUDE_PATTERN"
        for pattern in "${INCLUDE_ARRAY[@]}"; do
            pattern=$(echo "$pattern" | xargs) # trim whitespace
            if [[ "$site_name" == *"$pattern"* ]] || [[ "$path" == *"$pattern"* ]]; then
                return 0 # true - should process
            fi
        done
        return 1 # false - no include pattern matched
    fi
    
    return 0 # true - no filters or passed filters
}

# Display run mode
if [ "$DRY_RUN" = true ]; then
    echo "=========================================="
    echo "DRY RUN MODE - No changes will be applied"
    echo "=========================================="
fi

echo "Starting Apache memory fix application..."
echo "Source configuration: $SOURCE_CONF_DIR/$CONF_FILE"

if [ -n "$INCLUDE_PATTERN" ]; then
    echo "Including sites matching: $INCLUDE_PATTERN"
fi

if [ -n "$EXCLUDE_PATTERN" ]; then
    echo "Excluding sites matching: $EXCLUDE_PATTERN"
fi

echo ""

# Counter for statistics
TOTAL_FOUND=0
TOTAL_PROCESSED=0
TOTAL_SKIPPED=0
TOTAL_FILTERED=0
TOTAL_ALREADY_CONFIGURED=0

# Iterate over all docker-compose.yml files in the sites directory
find "$SEARCH_DIR" -maxdepth 2 -name "docker-compose.yml" | while read -r compose_file; do
    site_dir=$(dirname "$compose_file")
    site_name=$(basename "$site_dir")
    
    # Check if this compose file has a container matching 'wp_*'
    # We use yq to check the container_name of any service
    if yq '.services[] | select(.container_name | test("^wp_")) | .container_name' "$compose_file" 2>/dev/null | grep -q "wp_"; then
        TOTAL_FOUND=$((TOTAL_FOUND + 1))
        
        # Check if site should be processed based on filters
        if ! should_process "$site_dir"; then
            echo "[FILTERED] Skipping $site_name (excluded by filters)"
            TOTAL_FILTERED=$((TOTAL_FILTERED + 1))
            continue
        fi
        
        echo "--------------------------------------------------"
        echo "Found WordPress container in: $site_name"
        echo "Path: $site_dir"
        
        # Check if volume is already present (skip if --overwrite is set)
        if grep -q "mpm_prefork.conf:/etc/apache2/mods-available/mpm_prefork.conf" "$compose_file"; then
            if [ "$OVERWRITE" = false ]; then
                echo "[ALREADY CONFIGURED] Configuration already present in docker-compose.yml."
                TOTAL_ALREADY_CONFIGURED=$((TOTAL_ALREADY_CONFIGURED + 1))
                continue
            else
                echo "[OVERWRITE MODE] Updating existing configuration..."
            fi
        fi
        
        if [ "$DRY_RUN" = true ]; then
            echo "[DRY RUN] Would perform the following actions:"
            echo "  1. Backup docker-compose.yml to docker-compose.yml.bak"
            echo "  2. Copy $CONF_FILE to $site_dir/"
            if [ "$APPLY_PHP_FPM" = true ]; then
                echo "  3. Copy $PHP_FPM_CONF to $site_dir/"
            fi
            if [ "$APPLY_PHP_LIMITS" = true ]; then
                echo "  4. Copy $PHP_LIMITS_INI to $site_dir/"
            fi
            echo "  5. Add volume mount: ./mpm_prefork.conf:/etc/apache2/mods-available/mpm_prefork.conf"
            if [ "$APPLY_PHP_FPM" = true ]; then
                echo "  6. Add volume mount: ./$PHP_FPM_CONF:/usr/local/etc/php-fpm.d/www.conf"
            fi
            if [ "$APPLY_PHP_LIMITS" = true ]; then
                echo "  7. Add volume mount: ./$PHP_LIMITS_INI:/usr/local/etc/php/conf.d/99-limits.ini"
            fi
            if [ "$RESTART" = true ]; then
                echo "  8. Restart containers: docker compose down && docker compose up -d"
            fi
            TOTAL_PROCESSED=$((TOTAL_PROCESSED + 1))
        else
            # 1. Backup
            if [ ! -f "$compose_file.bak" ]; then
                echo "Backing up docker-compose.yml..."
                cp "$compose_file" "$compose_file.bak"
            else
                echo "Backup already exists, skipping backup."
            fi

            # 2. Copy the config files
            echo "Copying $CONF_FILE to $site_dir..."
            cp "$SOURCE_CONF_DIR/$CONF_FILE" "$site_dir/$CONF_FILE"
            
            if [ "$APPLY_PHP_FPM" = true ]; then
                echo "Copying $PHP_FPM_CONF to $site_dir..."
                cp "$SOURCE_CONF_DIR/$PHP_FPM_CONF" "$site_dir/$PHP_FPM_CONF"
            fi
            
            if [ "$APPLY_PHP_LIMITS" = true ]; then
                echo "Copying $PHP_LIMITS_INI to $site_dir..."
                cp "$SOURCE_CONF_DIR/$PHP_LIMITS_INI" "$site_dir/$PHP_LIMITS_INI"
            fi

            # 3. Apply changes with yq
            echo "Patching docker-compose.yml..."
            yq -i '(.services[] | select(.container_name | test("^wp_"))).volumes += ["./mpm_prefork.conf:/etc/apache2/mods-available/mpm_prefork.conf"]' "$compose_file"
            
            if [ "$APPLY_PHP_FPM" = true ]; then
                echo "Adding PHP-FPM pool configuration volume..."
                yq -i '(.services[] | select(.container_name | test("^wp_"))).volumes += ["./'"$PHP_FPM_CONF"':/usr/local/etc/php-fpm.d/www.conf"]' "$compose_file"
            fi
            
            if [ "$APPLY_PHP_LIMITS" = true ]; then
                echo "Adding PHP limits configuration volume..."
                yq -i '(.services[] | select(.container_name | test("^wp_"))).volumes += ["./'"$PHP_LIMITS_INI"':/usr/local/etc/php/conf.d/99-limits.ini"]' "$compose_file"
            fi
            
            echo "✓ Successfully patched $site_name"
            TOTAL_PROCESSED=$((TOTAL_PROCESSED + 1))
            
            # 4. Restart containers if requested
            if [ "$RESTART" = true ]; then
                echo "Restarting containers..."
                (cd "$site_dir" && docker compose down && docker compose up -d)
                echo "✓ Containers restarted for $site_name"
            fi
        fi
        
    else
        # Silent skip for non-wp containers to avoid noise
        TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
    fi
done

# Summary
echo ""
echo "=================================================="
echo "Summary"
echo "=================================================="
echo "WordPress sites found:        $TOTAL_FOUND"
echo "Sites processed:              $TOTAL_PROCESSED"
echo "Sites already configured:     $TOTAL_ALREADY_CONFIGURED"
echo "Sites filtered out:           $TOTAL_FILTERED"
echo "Non-WordPress sites skipped:  $TOTAL_SKIPPED"
echo "=================================================="

if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "This was a DRY RUN. No changes were applied."
    echo "Run without --dry-run to apply changes."
fi

echo ""
echo "Batch update complete."
