#!/bin/bash

# Script 1: Backup WordPress Site
# This script identifies WordPress Docker containers, lets the user select one,
# and creates a backup tarball of its database and files.

set -auo pipefail # Exit immediately if a command exits with a non-zero status.

# --- Function Definitions ---

# Display usage information
function display_help() {
    echo "Usage: $0 [--backup-dir /path/to/backups] [--selection <number>] [--db-password <password>] [--dry-run] [--wp-db-export]"
    echo
    echo "This script finds running WordPress containers and backs up a selected site."
    echo
    echo "Parameters:"
    echo "  --backup-dir <path>  Set the directory to save the backup tarball. If not provided, the script will prompt for it."
    echo "  --selection <number> Pre-select the site by number (1-based index). If not provided, the script will prompt for selection."
    echo "  --db-password <pass> Set the database password. If not provided, will attempt to extract from container."
    echo "  --dry-run            Display the commands that would be executed without performing the backup."
    echo "  --wp-db-export       Use WP-CLI inside the WordPress container to export the database (wp db export)."
    echo "  --help               Display this help message."
    exit 0
}

# --- Main Script Logic ---

# Set default values
BACKUP_DIR="backups"
SELECTION=""
DB_PASSWORD=""
DRY_RUN=false
WP_DB_EXPORT=false

# Parse command-line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --backup-dir)
            BACKUP_DIR="$2"
            shift
            ;;
        --selection)
            SELECTION="$2"
            shift
            ;;
        --db-password)
            DB_PASSWORD="$2"
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            ;;
        --wp-db-export)
            WP_DB_EXPORT=true
            ;;
        --help)
            display_help
            ;;
        *)
            echo "Unknown parameter: $1"
            display_help
            ;;
    esac
    shift
done

echo "--- WordPress Site Backup ---"

# Step 1: Scan for WordPress containers and get their details
echo "Scanning for available WordPress containers..."

# Find containers using the 'wordpress' image, get their name and associated URL (VIRTUAL_HOST env var)
# The output format is: ContainerName:SiteURL:SiteDir
mapfile -t sites < <(docker ps --filter "name=wp_*" --format "{{.Names}}:{{.ID}}" | while IFS=: read -r name id; do
    # Extract the site domain from Traefik labels
    site_url=$(docker inspect "$id" --format '{{range $key, $value := .Config.Labels}}{{if eq $key "traefik.http.routers.'$name'.rule"}}{{$value}}{{end}}{{end}}' | grep -o 'Host(`[^`]*`)' | head -1 | sed 's/Host(`\([^`]*\)`)/\1/')
    
    # If no Traefik label found, try to extract from mount paths
    if [ -z "$site_url" ]; then
        site_url=$(docker inspect "$id" --format '{{range .Mounts}}{{if contains .Source "/var/opt/"}}{{.Source}}{{end}}{{end}}' | head -1 | sed 's|/var/opt/\([^/]*\)/.*|\1|')
    fi
    
    if [ -n "$site_url" ]; then
        site_dir="/var/opt/$site_url"
        if [ -d "$site_dir" ]; then
            echo "$name:$site_url:$site_dir"
        else
            echo "Debug: Directory $site_dir not found for container $name" >&2
        fi
    else
        echo "Debug: Could not determine site URL for container $name" >&2
    fi
done)

if [ ${#sites[@]} -eq 0 ]; then
    echo "No running WordPress containers found with an associated directory in /var/opt/. Exiting."
    exit 1
fi

# Step 2: Display a numbered list for user selection
echo "Please select a site to back up:"
i=1
for site_details in "${sites[@]}"; do
    container_name=$(echo "$site_details" | cut -d':' -f1)
    url=$(echo "$site_details" | cut -d':' -f2)
    echo "$i) $url - ($container_name)"
    i=$((i+1))
done

# Step 3: Get user's selection
if [ -n "$SELECTION" ]; then
    selection="$SELECTION"
    echo "Using pre-selected site: $selection"
else
    read -p "Enter the number of the site: " selection
fi

if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt ${#sites[@]} ]; then
    echo "Invalid selection. Please run the script again."
    exit 1
fi

selected_site_details=${sites[$((selection-1))]}
CONTAINER_NAME=$(echo "$selected_site_details" | cut -d':' -f1)
SITE_URL=$(echo "$selected_site_details" | cut -d':' -f2)
SITE_DIR=$(echo "$selected_site_details" | cut -d':' -f3)

# Validate that we have all required values
if [ -z "$CONTAINER_NAME" ] || [ -z "$SITE_URL" ] || [ -z "$SITE_DIR" ]; then
    echo "Error: Failed to extract container details. Selected: $selected_site_details"
    exit 1
fi

echo "You selected: $SITE_URL"

# Step 4: Get backup directory if not provided
if [ -z "$BACKUP_DIR" ]; then
    read -p "Enter the backup directory path: " BACKUP_DIR
fi

# Validate backup directory is not empty
# if [ -z "$BACKUP_DIR" ]; then
#     echo "Error: Backup directory cannot be empty."
#     exit 1
# fi

# Create backup directory if it doesn't exist
if ! [ -d "$BACKUP_DIR" ]; then
    echo "Backup directory '$BACKUP_DIR' not found."
    if ! $DRY_RUN; then
        echo "Creating it..."
        mkdir -p "$BACKUP_DIR"
    else
        echo "[Dry Run] Would create directory: mkdir -p '$BACKUP_DIR'"
    fi
fi

# Define backup file names
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
DB_BACKUP_FILE="db_export_${TIMESTAMP}.sql"
FINAL_TARBALL="${BACKUP_DIR}/${SITE_URL}_backup_${TIMESTAMP}.tar.gz"

echo "Backup will be saved to: $FINAL_TARBALL"

# Step 5: Perform the backup
if $DRY_RUN; then
    echo
    echo "--- [Dry Run] Commands ---"
    if $WP_DB_EXPORT; then
        echo "# 1. Export the database using WP-CLI in the WordPress container:"
        echo "docker exec -u 0 $CONTAINER_NAME wp --allow-root db export"
    else
        echo "# 1. Export the database:"
        echo "docker exec mysql mysqldump -p\$DB_PASSWORD \$DB_NAME > '$SITE_DIR/$DB_BACKUP_FILE'"
    fi
    echo "# 2. Create the site tarball:"
    echo "tar -czf '$FINAL_TARBALL' -C '$SITE_DIR' ."
    echo "# 3. Clean up the temporary database export:"
    echo "rm '$SITE_DIR/$DB_BACKUP_FILE'"
    echo "--- [Dry Run] Complete ---"
else
    echo
    echo "--- Starting Backup ---"
    # a) Export the database
    if $WP_DB_EXPORT; then
        echo "1. Exporting database from container '$CONTAINER_NAME' using WP-CLI..."
        if docker exec -u 0 "$CONTAINER_NAME" wp --allow-root db export; then
            echo "Database exported successfully using WP-CLI"
        else
            echo "Error exporting database using WP-CLI in $CONTAINER_NAME"
            exit 1
        fi
    else
        echo "1. Exporting database from container '$CONTAINER_NAME'..."
        # Extract database credentials from container environment
        DB_NAME=$(docker exec "$CONTAINER_NAME" printenv WORDPRESS_DB_NAME)
        DB_USER=$(docker exec "$CONTAINER_NAME" printenv WORDPRESS_DB_USER)
        # DB_PASSWORD=$(docker exec "$CONTAINER_NAME" printenv WORDPRESS_DB_PASSWORD)
        DB_HOST=$(docker exec "$CONTAINER_NAME" printenv WORDPRESS_DB_HOST)
        
        # Validate we have all required credentials
        if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASSWORD" ] || [ -z "$DB_HOST" ]; then
            echo "Error: Could not retrieve all database credentials from container"
            echo "DB_NAME: $DB_NAME, DB_USER: $DB_USER, DB_HOST: $DB_HOST"
            exit 1
        fi
        
        # Use mysqldump via the mysql container to export the database
        if docker exec mysql mysqldump -p"$DB_PASSWORD" "$DB_NAME" > "$SITE_DIR/$DB_BACKUP_FILE"; then
            echo "Database exported successfully to $DB_BACKUP_FILE"
        else
            echo "Error exporting database from mysql container"
            echo "Database details: User=$DB_USER, Name=$DB_NAME"
            exit 1
        fi
    fi

    # b) Save the target dir as a tarball
    echo "2. Creating tarball of '$SITE_DIR'..."
    # Use -C to change directory so the paths in the tarball are relative
    tar -czf "$FINAL_TARBALL" -C "$SITE_DIR" .
    
    # Clean up the SQL file from the live site directory
    echo "3. Cleaning up temporary database file..."
    rm "$SITE_DIR/$DB_BACKUP_FILE" 2>/dev/null || true
    echo "Backup completed successfully!"

    echo "--- Backup Complete! ---"
    echo "Backup file created at: $FINAL_TARBALL"
fi
