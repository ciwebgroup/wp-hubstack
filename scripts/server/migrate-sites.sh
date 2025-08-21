#!/bin/bash

# Migrates 1 or more sites to a new server
# Usage:
#   ./migrate-sites.sh --sites <sites_glob> --target <target_server> [--dry-run]
#   ./migrate-sites.sh --config <config.yml> [--pause-to-confirm-migration] [--dry-run]
# Example:
#   ./migrate-sites.sh --sites [a-c]*.com --target wp18.example.com
#   ./migrate-sites.sh --config sites-to-migrate.yml --pause-to-confirm-migration

# source "$(dirname "$0")/../.env"
. .env

CF_TOKEN=${CLOUDFLARE_API_TOKEN}
CF_ACCOUNT_NUMBER=${CLOUDFLARE_ACCOUNT_NUMBER}

# Display usage if --help is provided or no parameters are supplied
function display_help() {
    echo "Usage: $0 [options]"
    echo "
Options:
  --sites <sites_glob>                Set the glob pattern to match sites for migration (e.g. [a-c]*.com).
  --target <target_server>            Set the target server IP or hostname for --sites option.
  --config <config.yml>               Set the YAML configuration file for migration.
  --pause-to-confirm-migration      Pause after each migration for manual confirmation and verification.
  --dry-run                           Display a summary of sites to migrate without making any changes.
  --help                              Display this help message."
    exit 0
}

# Default to displaying help if no parameters are supplied
if [ $# -eq 0 ]; then
    display_help
fi

# Set default values for variables
SITES_GLOB=""
TARGET_SERVER=""
CONFIG_FILE=""
PAUSE_FOR_CONFIRM=false
DRY_RUN=false

# Parse parameters
while [ "$1" != "" ]; do
    case $1 in
        --help)
            display_help
            ;;
        --sites)
            shift
            SITES_GLOB=$1
            ;;
        --target)
            shift
            TARGET_SERVER=$1
            ;;
        --config)
            shift
            CONFIG_FILE=$1
            ;;
        --pause-to-confirm-migration)
            PAUSE_FOR_CONFIRM=true
            ;;
        --dry-run)
            DRY_RUN=true
            ;;
        *)
            echo "Unknown parameter: $1"
            display_help
            ;;
    esac
    shift
done

# Check for mandatory parameters
if [ -z "$CONFIG_FILE" ] && ([ -z "$SITES_GLOB" ] || [ -z "$TARGET_SERVER" ]); then
    echo "Error: You must specify either --config or both --sites and --target."
    display_help
fi

if [ -n "$CONFIG_FILE" ] && ([ -n "$SITES_GLOB" ] || [ -n "$TARGET_SERVER" ]); then
    echo "Error: --config cannot be used with --sites or --target."
    display_help
fi

# Check for yq if --config is used
if [ -n "$CONFIG_FILE" ]; then
    if ! command -v yq &> /dev/null; then
        echo "Error: 'yq' is not installed. Please install it to use the --config option."
        echo "See: https://github.com/mikefarah/yq/#install"
        exit 1
    fi
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Error: Config file not found: $CONFIG_FILE"
        exit 1
    fi
fi

# Dry run summary
if [ "$DRY_RUN" = true ]; then
    echo "Dry run summary:"
    if [ -n "$CONFIG_FILE" ]; then
        SITES_TO_MIGRATE=$(yq e 'keys | .[]' "$CONFIG_FILE")
    else
        # Use find -print0 and xargs -0 to safely handle non-alphanumeric filenames
        SITES_TO_MIGRATE=$(find "$DOMAIN_PATH" -maxdepth 1 -type d -name "$SITES_GLOB" -print0 2>/dev/null | xargs -0 -n 1 basename)
    fi

    if [ -z "$SITES_TO_MIGRATE" ]; then
        if [ -n "$CONFIG_FILE" ]; then
            echo "No sites found in the config file: $CONFIG_FILE"
        else
            echo "No sites found for the given glob pattern: $SITES_GLOB"
        fi
    else
        echo "Sites to migrate:"
        echo "$SITES_TO_MIGRATE"
        echo "Total count: $(echo "$SITES_TO_MIGRATE" | wc -l)"
    fi
    exit 0
fi

# Check SSH key and generate if not present
if [ ! -f ~/.ssh/id_ed25519.pub ]; then
    echo "SSH key not found. Generating a new SSH key..."
    ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
fi

function confirm_and_verify() {
    local site=$1
    local target_server=$2
    local site_dir="$DOMAIN_PATH/$site"
    
    while true; do
        echo "----------------------------------------------------------------"
        echo "ACTION REQUIRED on target server: $target_server"
        echo "1. Log into the target server: ssh $target_server"
        echo "2. Start the site container: cd $site_dir && docker compose up -d"
        echo "3. Restart the proxy manager: cd $DOMAIN_PATH/wordpress-manager && docker compose down && docker compose up -d"
        echo "----------------------------------------------------------------"
        read -p "Have you completed these steps? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "Verifying site status..."
            STATUS_CODE=$(curl -o /dev/null -s -w "%{http_code}" "https://$site")
            if [ "$STATUS_CODE" == "200" ]; then
                echo "Site is up! (Status: 200). Proceeding."
                break
            else
                echo "Verification failed. Site returned status code: $STATUS_CODE"
                read -p "Retry verification? (y/n) " -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    echo "Skipping further actions for this site."
                    return 1
                fi
            fi
        else
            echo "Aborting migration for $site."
            return 1
        fi
    done
    return 0
}

function migrate_site() {
    local SITE_TO_MIGRATE=$1
    local TARGET_SERVER=$2
    local MV_TO_DIR=$3

    if [ ! -d "$DOMAIN_PATH/$SITE_TO_MIGRATE" ]; then
        echo "$SITE_TO_MIGRATE: does not exist in $DOMAIN_PATH/."
        return
    fi

    DB=$(grep "  wp_" "$DOMAIN_PATH/$SITE_TO_MIGRATE/docker-compose.yml" | sed 's|[ :]||g')

    if [ -z "$DB" ]; then
        echo "Skipping $SITE_TO_MIGRATE: Database not found."
        return
    fi

    echo "Migrating site: $SITE_TO_MIGRATE to $TARGET_SERVER"

    # Check SSH access to target server
    ssh -q -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 "$TARGET_SERVER" exit
    if [ $? -ne 0 ]; then
        echo "Error: SSH access to $TARGET_SERVER is not available. Please add this key to the target server:"
        cat ~/.ssh/id_ed25519.pub
        exit 1
    fi

    # Dump the database
    echo "Dumping database: $DB"
    docker exec mysql mysqldump -p"$MYSQL_PASS" "$DB" > "$DOMAIN_PATH/$SITE_TO_MIGRATE/www/wp-content/mysql.sql"

    # Rsync site files to target server
    echo "Rsyncing files to target server: $TARGET_SERVER"
    rsync -azv "$DOMAIN_PATH/$SITE_TO_MIGRATE" "$TARGET_SERVER:$DOMAIN_PATH/"

    # Perform IP lookup for the domain's new host
    TARGET_HOSTNAME=$(echo "$TARGET_SERVER" | cut -d'@' -f2)
    NEW_IP=$(dig +short "$TARGET_HOSTNAME")
    if [ -z "$NEW_IP" ]; then
        echo "Error: Could not determine new IP address for $TARGET_HOSTNAME. Skipping DNS update."
        return
    fi

    if [ "$PAUSE_FOR_CONFIRM" = true ]; then
        if ! confirm_and_verify "$SITE_TO_MIGRATE" "$TARGET_SERVER"; then
            echo "Migration for $SITE_TO_MIGRATE paused or aborted by user."
            return
        fi
    fi

    # Get the zone ID for the domain
    ZONE_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?account.id=$CF_ACCOUNT_NUMBER&name=$SITE_TO_MIGRATE" \
        -H "Authorization: Bearer $CF_TOKEN" \
        -H "Content-Type: application/json")
    ZONE_ID=$(echo "$ZONE_RESPONSE" | jq -r '.result[0].id')
    if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" == "null" ]; then
        echo "Error: Could not retrieve zone ID for $SITE_TO_MIGRATE. Skipping DNS update."
        return
    fi

    # Get the record ID for the A record
    RECORD_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$SITE_TO_MIGRATE" \
        -H "Authorization: Bearer $CF_TOKEN" \
        -H "Content-Type: application/json")
    RECORD_ID=$(echo "$RECORD_RESPONSE" | jq -r '.result[0].id')
    if [ -z "$RECORD_ID" ] || [ "$RECORD_ID" == "null" ]; then
        echo "Error: Could not retrieve DNS record ID for $SITE_TO_MIGRATE. Skipping DNS update."
        return
    fi

    # Update DNS via Cloudflare API
    echo "Updating DNS for $SITE_TO_MIGRATE to IP $NEW_IP via Cloudflare API..."
    RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
        -H "Authorization: Bearer $CF_TOKEN" \
        -H "Content-Type: application/json" \
        --data '{"type":"A","name":"'$SITE_TO_MIGRATE'","content":"'$NEW_IP'","ttl":120,"proxied":false}')

    if [[ $(echo "$RESPONSE" | jq -r '.success') == "true" ]]; then
        echo "DNS update successful for $SITE_TO_MIGRATE."
        local final_dir="$DOMAIN_PATH/$SITE_TO_MIGRATE"
        if [ -n "$MV_TO_DIR" ]; then
            echo "Moving site directory to $MV_TO_DIR on source server."
            mkdir -p "$MV_TO_DIR"
            mv "$DOMAIN_PATH/$SITE_TO_MIGRATE" "$MV_TO_DIR/"
            final_dir="$MV_TO_DIR/$SITE_TO_MIGRATE"
        fi
        echo "Creating migration timestamp..."
        date +%s > "$final_dir/migration_timestamp"
        if [ "$PAUSE_FOR_CONFIRM" = false ]; then
            echo "Now hurry and connect to $TARGET_SERVER and run: cd $DOMAIN_PATH/$SITE_TO_MIGRATE && docker compose up -d"
        fi
    else
        echo "Error: DNS could not be automatically updated for $SITE_TO_MIGRATE. Response: $RESPONSE"
    fi
}

# Main migration loop
if [ -n "$CONFIG_FILE" ]; then
    SITES=$(yq e 'keys | .[]' "$CONFIG_FILE")
    for site in $SITES; do
        target=$(yq e ".[\"$site\"].to" "$CONFIG_FILE")
        mvDir=$(yq e ".[\"$site\"].mvToDir" "$CONFIG_FILE")
        migrate_site "$site" "$target" "$mvDir"
        echo "----------------------------------------"
    done
else
    # Ensure TARGET_SERVER has user if not provided
    if [[ $TARGET_SERVER != *"@"* ]]; then
        TARGET_SERVER="root@$TARGET_SERVER"
    fi
    find "$DOMAIN_PATH" -maxdepth 1 -type d -name "$SITES_GLOB" -print0 2>/dev/null | xargs -0 -n1 basename | while IFS= read -r SITE_TO_MIGRATE; do
        migrate_site "$SITE_TO_MIGRATE" "$TARGET_SERVER" ""
        echo "----------------------------------------"
    done
fi

echo "All migrations complete."
