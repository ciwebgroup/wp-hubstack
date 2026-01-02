#!/bin/bash

# MetaSync Rate Limiter - Multi-Site WordPress Rate Limiting for Cloudflare
# This script automatically discovers WordPress sites from Docker containers
# and applies rate limiting rules to their Cloudflare zones.

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
DRY_RUN=false
INCLUDE_PATTERN=""
EXCLUDE_PATTERN=""
API_BASE="https://api.cloudflare.com/client/v4"

# Help function
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

MetaSync Rate Limiter - Apply WordPress rate limiting rules to Cloudflare zones
for all dockerized WordPress sites.

OPTIONS:
    --include PATTERN    Only process sites matching this pattern (grep-style)
    --exclude PATTERN    Skip sites matching this pattern (grep-style)
    --dry-run           Show what would be done without making changes
    --help              Show this help message

EXAMPLES:
    # Process all sites
    $(basename "$0")

    # Process only sites containing "example"
    $(basename "$0") --include "example"

    # Process all sites except those containing "staging"
    $(basename "$0") --exclude "staging"

    # Preview changes without applying them
    $(basename "$0") --dry-run

    # Combine filters
    $(basename "$0") --include "prod" --exclude "test" --dry-run

DESCRIPTION:
    This script discovers WordPress sites from running Docker containers,
    retrieves their Cloudflare zone IDs, and applies rate limiting rules
    to protect against abuse of:
    - WordPress admin AJAX endpoints
    - MetaSync/SearchAtlas REST API endpoints
    - WP-Cron
    - XML-RPC

    Cloudflare credentials are loaded from /var/opt/scripts/.env.cf-keys

EOF
    exit 0
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --include)
            INCLUDE_PATTERN="$2"
            shift 2
            ;;
        --exclude)
            EXCLUDE_PATTERN="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help)
            show_help
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Load Cloudflare credentials
ENV_FILE="/var/opt/scripts/.env.cf-keys"
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}❌ Error: Cloudflare credentials file not found: $ENV_FILE${NC}"
    echo "Please create the file with CF_API_TOKEN defined"
    exit 1
fi

source "$ENV_FILE"

if [ -z "$CF_API_TOKEN" ]; then
    echo -e "${RED}❌ Error: CF_API_TOKEN not set in $ENV_FILE${NC}"
    exit 1
fi

CF_TOKEN="$CF_API_TOKEN"

if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}🔍 DRY RUN MODE - No changes will be made${NC}"
    echo ""
fi

# Get container names
echo -e "${BLUE}🐳 Discovering WordPress containers...${NC}"
readarray -t container_names < <(docker ps --format '{{.Names}}')

if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Failed to retrieve container names${NC}"
    exit 1
fi

websites=()
containers=()

# Extract websites from containers
for container in "${container_names[@]}"; do
    if ! website=$(docker inspect "$container" | jq -r '.[].Config.Env[] | select(test("^WP_HOME="))' | cut -d= -f2); then
        continue
    fi
    
    if [ -z "$website" ]; then
        continue
    fi
    
    # Strip protocol and www.
    clean_website="${website#http://}"
    clean_website="${clean_website#https://}"
    clean_website="${clean_website#www.}"
    
    # Apply include filter
    if [ -n "$INCLUDE_PATTERN" ]; then
        if ! echo "$clean_website" | grep -q "$INCLUDE_PATTERN"; then
            echo -e "${YELLOW}⏭️  Skipping $clean_website (doesn't match include pattern)${NC}"
            continue
        fi
    fi
    
    # Apply exclude filter
    if [ -n "$EXCLUDE_PATTERN" ]; then
        if echo "$clean_website" | grep -q "$EXCLUDE_PATTERN"; then
            echo -e "${YELLOW}⏭️  Skipping $clean_website (matches exclude pattern)${NC}"
            continue
        fi
    fi
    
    websites+=("$clean_website")
    containers+=("$container")
done

echo -e "${GREEN}✅ Found ${#websites[@]} WordPress site(s) to process${NC}"
echo ""

# Function to get Zone ID for a domain
get_zone_id() {
    local domain="$1"
    
    ZONE_RESPONSE=$(curl -s "$API_BASE/zones?name=$domain" \
        --header "Authorization: Bearer $CF_TOKEN" \
        --header "Content-Type: application/json")
    
    ZONE_ID=$(echo "$ZONE_RESPONSE" | jq -r '.result[0].id // empty')
    echo "$ZONE_ID"
}

# Function to check if ruleset exists
get_or_create_ruleset() {
    local zone_id="$1"
    local domain="$2"
    
    RESPONSE=$(curl -s "$API_BASE/zones/$zone_id/rulesets/phases/http_ratelimit/entrypoint" \
        --header "Authorization: Bearer $CF_TOKEN" \
        --header "Content-Type: application/json")
    
    RULESET_ID=$(echo "$RESPONSE" | jq -r '.result.id // empty')
    
    if [ -z "$RULESET_ID" ]; then
        echo -e "${YELLOW}   📝 No ruleset found. Creating new http_ratelimit ruleset...${NC}"
        
        if [ "$DRY_RUN" = true ]; then
            echo -e "${YELLOW}   [DRY RUN] Would create ruleset for $domain${NC}"
            echo "CREATE"
            return
        fi
        
        CREATE_RESPONSE=$(curl -s "$API_BASE/zones/$zone_id/rulesets" \
            --request POST \
            --header "Authorization: Bearer $CF_TOKEN" \
            --header "Content-Type: application/json" \
            --data '{
                "name": "WordPress Rate Limiting",
                "kind": "zone",
                "phase": "http_ratelimit",
                "rules": []
            }')
        
        RULESET_ID=$(echo "$CREATE_RESPONSE" | jq -r '.result.id // empty')
        
        if [ -z "$RULESET_ID" ]; then
            echo -e "${RED}   ❌ Failed to create ruleset${NC}"
            echo "$CREATE_RESPONSE" | jq .
            echo "ERROR"
            return
        fi
        
        echo -e "${GREEN}   ✅ Created ruleset: $RULESET_ID${NC}"
    fi
    
    echo "$RULESET_ID"
}

# Function to add a rate limiting rule
add_rule() {
    local zone_id="$1"
    local ruleset_id="$2"
    local description="$3"
    local expression="$4"
    local requests_per_period="$5"
    local period="$6"
    local mitigation_timeout="$7"
    local action="${8:-block}"
    
    echo -e "   📝 Adding rule: $description..."
    
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}   [DRY RUN] Would add rule: $description${NC}"
        echo -e "${YELLOW}   Expression: $expression${NC}"
        echo -e "${YELLOW}   Rate: $requests_per_period requests per $period seconds${NC}"
        return 0
    fi
    
    RULE_RESPONSE=$(curl -s "$API_BASE/zones/$zone_id/rulesets/$ruleset_id/rules" \
        --request POST \
        --header "Authorization: Bearer $CF_TOKEN" \
        --header "Content-Type: application/json" \
        --data "{
            \"description\": \"$description\",
            \"expression\": \"$expression\",
            \"action\": \"$action\",
            \"action_parameters\": {
                \"response\": {
                    \"status_code\": 429,
                    \"content\": \"{\\\"error\\\": \\\"Rate limit exceeded\\\"}\",
                    \"content_type\": \"application/json\"
                }
            },
            \"ratelimit\": {
                \"characteristics\": [\"ip.src\"],
                \"period\": $period,
                \"requests_per_period\": $requests_per_period,
                \"mitigation_timeout\": $mitigation_timeout,
                \"requests_to_origin\": true
            }
        }")
    
    SUCCESS=$(echo "$RULE_RESPONSE" | jq -r '.success')
    if [ "$SUCCESS" = "true" ]; then
        echo -e "${GREEN}      ✅ Rule added successfully${NC}"
        return 0
    else
        echo -e "${RED}      ❌ Failed to add rule${NC}"
        echo "$RULE_RESPONSE" | jq '.errors'
        return 1
    fi
}

# Process each site
success_count=0
fail_count=0
success_sites=()
fail_sites=()

for ((i=0; i<${#websites[@]}; i++)); do
    website="${websites[i]}"
    container="${containers[i]}"
    
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}🌐 Processing: $website${NC}"
    echo -e "${BLUE}   Container: $container${NC}"
    echo ""
    
    # Get Zone ID
    echo "   🔍 Looking up Cloudflare Zone ID..."
    ZONE_ID=$(get_zone_id "$website")
    
    if [ -z "$ZONE_ID" ]; then
        echo -e "${RED}   ❌ No Cloudflare zone found for $website${NC}"
        fail_count=$((fail_count+1))
        fail_sites+=("$website")
        echo ""
        continue
    fi
    
    echo -e "${GREEN}   ✅ Zone ID: $ZONE_ID${NC}"
    
    # Get or create ruleset
    echo "   🔍 Checking for existing rate limiting ruleset..."
    RULESET_ID=$(get_or_create_ruleset "$ZONE_ID" "$website")
    
    if [ "$RULESET_ID" = "ERROR" ]; then
        fail_count=$((fail_count+1))
        fail_sites+=("$website")
        echo ""
        continue
    fi
    
    if [ "$RULESET_ID" = "CREATE" ]; then
        # Dry run mode - ruleset would be created
        success_count=$((success_count+1))
        success_sites+=("$website")
        echo ""
        continue
    fi
    
    echo -e "${GREEN}   ✅ Ruleset ID: $RULESET_ID${NC}"
    echo ""
    
    # Add WordPress protection rules
    echo "   🛡️  Applying rate limiting rules..."
    
    add_rule "$ZONE_ID" "$RULESET_ID" \
        "Rate limit WordPress admin AJAX" \
        "(http.request.uri.path contains \"/wp-admin/admin-ajax.php\")" \
        60 60 120
    
    add_rule "$ZONE_ID" "$RULESET_ID" \
        "Rate limit MetaSync REST API" \
        "(http.request.uri.path contains \"/wp-json/metasync/\" or http.request.uri.path contains \"/wp-json/searchatlas/\")" \
        30 60 300
    
    add_rule "$ZONE_ID" "$RULESET_ID" \
        "Limit WP-Cron frequency" \
        "(http.request.uri.path eq \"/wp-cron.php\")" \
        2 60 60
    
    add_rule "$ZONE_ID" "$RULESET_ID" \
        "Block XML-RPC abuse" \
        "(http.request.uri.path eq \"/xmlrpc.php\")" \
        5 10 600
    
    echo ""
    echo -e "${GREEN}   ✅ Rate limiting configured for $website${NC}"
    
    if [ "$DRY_RUN" = false ]; then
        echo -e "${BLUE}   🔗 View rules: https://dash.cloudflare.com/?zone=$ZONE_ID/security/waf/rate-limiting-rules${NC}"
    fi
    
    success_count=$((success_count+1))
    success_sites+=("$website")
    echo ""
done

# Print summary
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}📊 SUMMARY${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${GREEN}✅ Successfully processed: $success_count site(s)${NC}"
for site in "${success_sites[@]}"; do
    echo -e "   - $site"
done
echo ""

if [ $fail_count -gt 0 ]; then
    echo -e "${RED}❌ Failed to process: $fail_count site(s)${NC}"
    for site in "${fail_sites[@]}"; do
        echo -e "   - $site"
    done
    echo ""
fi

if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}🔍 This was a dry run. No changes were made.${NC}"
    echo -e "${YELLOW}Run without --dry-run to apply changes.${NC}"
fi

echo ""
echo -e "${GREEN}🎉 Done!${NC}"
