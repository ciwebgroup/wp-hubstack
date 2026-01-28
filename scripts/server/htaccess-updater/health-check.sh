#!/bin/bash

# Health Check Script for WordPress Sites
# Verifies both site availability and log file blocking
# Extracts URLs from Docker containers starting with wp_

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
TOTAL_SITES=0
PASSED_SITES=0
FAILED_SITES=0
SKIPPED_SITES=0

# Log file paths to test (should return 403/401/404)
BLOCKED_PATHS=(
    "debug.log"
    "error_log"
    "php_errorlog"
    "wp-content/debug.log"
    "wp-content/uploads/debug.log"
    "test.log"
)

extract_wp_home() {
    local container_name="$1"
    local wp_home=""
    
    # Extract WP_HOME from container environment variables
    wp_home=$(docker inspect "$container_name" 2>/dev/null | jq -r '.[].Config.Env[] | select(startswith("WP_HOME=")) | sub("WP_HOME="; "")' 2>/dev/null || echo "")
    
    echo "$wp_home"
}

check_site() {
    local container_name="$1"
    local site_url="$2"
    local site_passed=true
    
    echo "========================================"
    echo -e "Container: ${BLUE}$container_name${NC}"
    echo "URL: $site_url"
    echo "========================================"
    
    # Check primary URL (expect 200)
    echo -n "  Primary URL... "
    primary_status=$(curl -o /dev/null -s -L -w "%{http_code}" "$site_url" 2>/dev/null || echo "000")
    
    if [ "$primary_status" = "200" ]; then
        echo -e "${GREEN}✓ OK (200)${NC}"
    else
        echo -e "${RED}✗ FAILED (got $primary_status, expected 200)${NC}"
        site_passed=false
    fi
    
    # Check blocked log files (expect 403, 401, or 404)
    for path in "${BLOCKED_PATHS[@]}"; do
        echo -n "  Blocked path (/$path)... "
        blocked_status=$(curl -o /dev/null -s -L -w "%{http_code}" "$site_url/$path" 2>/dev/null || echo "000")
        
        # Accept 403 (Forbidden), 401 (Unauthorized), or 404 (Not Found) as success
        if [ "$blocked_status" = "403" ] || [ "$blocked_status" = "401" ] || [ "$blocked_status" = "404" ]; then
            echo -e "${GREEN}✓ Blocked ($blocked_status)${NC}"
        elif [ "$blocked_status" = "200" ]; then
            echo -e "${RED}✗ EXPOSED (200 - file is accessible!)${NC}"
            site_passed=false
        else
            echo -e "${YELLOW}⚠ Unexpected ($blocked_status)${NC}"
        fi
    done
    
    # Summary for this site
    if [ "$site_passed" = true ]; then
        echo -e "${GREEN}✓ Site passed all checks${NC}"
        PASSED_SITES=$((PASSED_SITES + 1))
    else
        echo -e "${RED}✗ Site failed one or more checks${NC}"
        FAILED_SITES=$((FAILED_SITES + 1))
    fi
    
    echo ""
}

# Main execution
echo "=========================================="
echo "WordPress Site Health Check"
echo "=========================================="
echo ""

# Check if Docker is available
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Error: docker command not found${NC}"
    exit 1
fi

# Check if jq is available
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq command not found. Please install jq.${NC}"
    exit 1
fi

# Check if a specific container was provided
if [ -n "$1" ]; then
    # Single container mode
    container_name="$1"
    
    # Ensure container name starts with wp_ if not already
    if [[ ! "$container_name" =~ ^wp_ ]]; then
        container_name="wp_$container_name"
    fi
    
    echo -e "Checking single container: ${BLUE}$container_name${NC}"
    echo ""
    
    TOTAL_SITES=1
    site_url=$(extract_wp_home "$container_name")
    
    if [ -z "$site_url" ]; then
        echo -e "${YELLOW}⚠ Could not extract WP_HOME from $container_name. Skipping.${NC}"
        SKIPPED_SITES=$((SKIPPED_SITES + 1))
    else
        check_site "$container_name" "$site_url"
    fi
else
    # Multi-container mode - check all wp_ containers
    echo "Discovering wp_ containers..."
    
    # Get all container names starting with wp_
    mapfile -t containers < <(docker ps --filter "name=^wp_" --format "{{.Names}}" 2>/dev/null | sort)
    
    if [ ${#containers[@]} -eq 0 ]; then
        echo -e "${YELLOW}No running wp_ containers found.${NC}"
        exit 0
    fi
    
    echo -e "Found ${BLUE}${#containers[@]}${NC} wp_ containers"
    echo ""
    
    for container_name in "${containers[@]}"; do
        TOTAL_SITES=$((TOTAL_SITES + 1))
        
        site_url=$(extract_wp_home "$container_name")
        
        if [ -z "$site_url" ]; then
            echo "========================================"
            echo -e "Container: ${BLUE}$container_name${NC}"
            echo -e "${YELLOW}⚠ Could not extract WP_HOME. Skipping.${NC}"
            echo "========================================"
            echo ""
            SKIPPED_SITES=$((SKIPPED_SITES + 1))
            continue
        fi
        
        check_site "$container_name" "$site_url"
    done
fi

# Final summary
echo "=========================================="
echo "SUMMARY"
echo "=========================================="
echo "Total containers checked: $TOTAL_SITES"
echo -e "Passed: ${GREEN}$PASSED_SITES${NC}"
echo -e "Failed: ${RED}$FAILED_SITES${NC}"
if [ "$SKIPPED_SITES" -gt 0 ]; then
    echo -e "Skipped: ${YELLOW}$SKIPPED_SITES${NC}"
fi
echo ""

if [ "$FAILED_SITES" -gt 0 ]; then
    echo -e "${RED}Some sites failed health checks. Please review the output above.${NC}"
    exit 1
else
    echo -e "${GREEN}All sites passed health checks!${NC}"
    exit 0
fi
