#!/bin/bash

# source "$(dirname "$0")/../.env" # Is this necessary? 

# Load environment variables from .env file if it exists
SCRIPT_PATH="$(dirname "$(readlink -f "$0")")"
if [ -f "$SCRIPT_PATH/../.env" ]; then
  export "$(grep -v '^#' "$SCRIPT_PATH/../.env" | xargs)"
else
  echo "Warning: .env file not found. Using default environment variables."
fi

# Colors for messages
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No color

# Function to display help
show_help() {
  echo "Usage: $0 <domain> [NEW_ADMIN_EMAIL] [--dry-run] [--help]"
  echo
  echo "Script to cancel a WordPress site by deactivating plugins, removing license keys,"
  echo "exporting the database, and archiving the site directory."
  echo
  echo "Arguments:"
  echo "  <domain>            The base domain name of the WordPress site (e.g., example.com)."
  echo "  NEW_ADMIN_EMAIL     (Optional) The new email address to set for 'admin_email'."
  echo
  echo "Options:"
  echo "  --help              Display this help message."
  echo "  --dry-run           Perform a trial run with no changes made."
  echo
}


# --- Add dry‐run flag and parse arguments ---
DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      show_help
      exit 0
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    *)
      break
      ;;
  esac
done

# Validate domain parameter
if [ -z "$1" ]; then
  echo -e "${RED}Error: Domain parameter is required.${NC}"
  echo "Run '$0 --help' for usage."
  exit 1
fi  

# Check if zip is installed
if ! command -v zip &> /dev/null; then
  echo -e "${RED}Error: 'zip' is not installed.${NC}"
  echo "Please install it using: apt-get install zip"
  exit 1
fi

# Extract domain and remove TLD
FULL_DOMAIN=$1
NEW_ADMIN_EMAIL=$2
BASE_DOMAIN=$(echo "$FULL_DOMAIN" | sed -E 's/\.[a-z]{2,}$//')
CONTAINER_NAME="wp_$(echo "${BASE_DOMAIN}" | sed 's/-//g')"
# CONTAINER_NAME="wp_${BASE_DOMAIN}"
SITE_DIR="$SCRIPT_PATH/${FULL_DOMAIN}"
ZIP_FILE="${SITE_DIR}.zip"
WP_CONTENT_DIR="${SITE_DIR}/www/wp-content"

# Options to remove
OPTIONS_TO_REMOVE=(
  "license_number"
  "_elementor_pro_license_data"
  "_elementor_pro_license_data_fallback"
  "_elementor_pro_license_v2_data_fallback"
  "_elementor_pro_license_v2_data"
  "_transient_timeout_rg_gforms_license"
  "_transient_rg_gforms_license"
  "_transient_timeout_uael_license_status"
  "_transient_timeout_astra-addon_license_status"
)

# Function to run wp-cli command inside Docker container
run_wp() {
  docker exec -i "$CONTAINER_NAME" wp "$@" --skip-themes --quiet
}

# Verify that the domain's directory exists
if [ ! -d "$SITE_DIR" ]; then
  echo -e "${RED}Error: Directory ${SITE_DIR} does not exist. Ensure the domain is correct.${NC}"
  exit 1
fi

# Check if the container exists
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  echo -e "${RED}Error: Container ${CONTAINER_NAME} not found.${NC}"
  exit 1
fi

# Announce dry‐run
if [[ "$DRY_RUN" == true ]]; then
  echo -e "${GREEN}[DRY RUN] No changes will be made.${NC}"
fi

# Disconnect from malcare
if [[ "$DRY_RUN" == true ]]; then
  echo "[DRY RUN] Would run: wp malcare disconnect"
else
  run_wp malcare disconnect
fi

# Remove specified options
echo "Removing specified WordPress options..."
for OPTION in "${OPTIONS_TO_REMOVE[@]}"; do
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY RUN] Would delete option: $OPTION"
  else
    echo "Removing option: $OPTION"
    run_wp option delete "$OPTION"
  fi
done

# Update transient
if [[ "$DRY_RUN" == true ]]; then
  echo "[DRY RUN] Would update _transient_astra-addon_license_status to 0"
else
  echo "Updating option: _transient_astra-addon_license_status to value 0"
  run_wp option update "_transient_astra-addon_license_status" 0
fi

# Update admin_email
if [ -n "$NEW_ADMIN_EMAIL" ]; then
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY RUN] Would update admin_email to $NEW_ADMIN_EMAIL"
  else
    echo "Updating 'admin_email' to $NEW_ADMIN_EMAIL"
    run_wp option update "admin_email" "$NEW_ADMIN_EMAIL" \
      && echo -e "${GREEN}Admin email updated successfully.${NC}" \
      || echo -e "${RED}Failed to update admin_email.${NC}"
  fi
else
  NEW_ADMIN_EMAIL=$ADMIN_EMAIL
fi

# Add a new admin user
RANDOM_PASSWORD=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c12)
if [[ "$DRY_RUN" == true ]]; then
  echo "[DRY RUN] Would create admin user $NEW_ADMIN_EMAIL with password $RANDOM_PASSWORD"
else
  run_wp user create $NEW_ADMIN_EMAIL $NEW_ADMIN_EMAIL --role=administrator --display_name="New Admin" --user_nicename="New Admin" --first_name="New" --last_name="Admin" --user_pass="${RANDOM_PASSWORD}"
  run_wp user update $NEW_ADMIN_EMAIL $NEW_ADMIN_EMAIL --role=administrator --display_name="New Admin" --user_nicename="New Admin" --first_name="New" --last_name="Admin" --user_pass="${RANDOM_PASSWORD}"
fi

# Export the database
if [[ "$DRY_RUN" == true ]]; then
  echo "[DRY RUN] Would export DB to wp-content/mysql.sql"
else
  echo "Exporting database for $FULL_DOMAIN"
  run_wp db export "wp-content/mysql.sql"
fi

# Zip the site directory
if [[ "$DRY_RUN" == true ]]; then
  echo "[DRY RUN] Would zip ${SITE_DIR} to ${ZIP_FILE}"
else
  echo "Zipping site directory to ${ZIP_FILE}..."
  zip -rq "$ZIP_FILE" "$SITE_DIR"
  echo -e "\n${GREEN}Zipping completed.${NC}"
fi

# Ensure wp-content directory exists
if [ ! -d "$WP_CONTENT_DIR" ]; then
  echo -e "${RED}Error: wp-content directory ${WP_CONTENT_DIR} does not exist. Ensure the site structure is correct.${NC}"
  exit 1
fi

# Change ownership of the zip file and move it to wp-content
if [[ "$DRY_RUN" == true ]]; then
  echo "[DRY RUN] Would chown and mv ${ZIP_FILE} into ${WP_CONTENT_DIR}/"
else
  echo "Changing ownership of the zip file to www-data:www-data"
  chown www-data:www-data "$ZIP_FILE"

  echo "Moving zip file to wp-content directory: ${WP_CONTENT_DIR}"
  mv "$ZIP_FILE" "$WP_CONTENT_DIR/"
fi

echo -e "${GREEN}Cancellation process for $FULL_DOMAIN completed successfully: https://$FULL_DOMAIN/wp-content/$FULL_DOMAIN.zip ${NC}"
echo -e "NEW ADMIN EMAIL: ${NEW_ADMIN_EMAIL}"
echo -e "NEW ADMIN PASS: ${RANDOM_PASSWORD}"

CURRENT_EPOCH=$(date +%s)

# Print the current epoch time to the site dir and save it to a file called 'cancellation-epoch.txt'
if [[ "$DRY_RUN" == true ]]; then
  echo "[DRY RUN] Would write epoch $CURRENT_EPOCH to ${SITE_DIR}/cancellation-epoch.txt"
else
  echo "$CURRENT_EPOCH" > "$SITE_DIR/cancellation-epoch.txt"
fi
