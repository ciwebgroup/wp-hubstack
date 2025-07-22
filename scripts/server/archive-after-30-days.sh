#!/usr/bin/env bash
#
# auto-archive-cancelled-sites.sh
#
# Scans for WordPress containers that have a 'cancellation-epoch.txt' file
# with a timestamp older than 30 days. If found, it backs up the site
# (database and files) and then removes the container, site files, and
# database user/schema.
#
# Meant to be run as a cron job.
#
set -euo pipefail

# --- Configuration ---
BACKUP_DIR="/var/opt/backups"
GRACE_PERIOD_DAYS=30

# --- Command line argument handling ---
TEST_GRACE_PERIOD=false
DRY_RUN=false

for arg in "$@"; do
    case $arg in
        --test-grace-period)
            TEST_GRACE_PERIOD=true
            ;;
        --dry-run)
            DRY_RUN=true
            ;;
        *)
            error "Unknown argument: $arg"
            error "Usage: $0 [--test-grace-period] [--dry-run]"
            exit 1
            ;;
    esac
done

# --- Globals for Summary ---
ARCHIVED_COUNT=0
SKIPPED_COUNT=0
ERROR_COUNT=0
PROCESSED_COUNT=0
declare -a ARCHIVED_SITES
declare -a SKIPPED_SITES
declare -a ERROR_SITES

# --- Colors for logging ---
GREEN='\e[32m'; YELLOW='\e[33m'; RED='\e[91m'; BLUE='\e[34m'; RESET='\e[0m'
info()    { echo -e "${GREEN}$*${RESET}"; }
warn()    { echo -e "${YELLOW}$*${RESET}" >&2; }
error()   { echo -e "${RED}ERROR: $*${RESET}" >&2; }
success() { echo -e "${GREEN}✅  $*${RESET}"; }
dry_run() { echo -e "${BLUE}[DRY RUN] $*${RESET}"; }

# --- Prerequisite Checks ---
if ! command -v docker &>/dev/null; then
    error "Docker is not installed or not in PATH. Exiting."
    exit 1
fi
if ! command -v jq &>/dev/null; then
    error "jq is not installed or not in PATH. Exiting."
    exit 1
fi

# --- Functions ---

test_grace_period_countdown() {
    local grace_seconds=$((GRACE_PERIOD_DAYS * 24 * 60 * 60))
    info "Testing grace period countdown for $GRACE_PERIOD_DAYS days ($grace_seconds seconds)"
    info "Starting countdown from $grace_seconds seconds..."
    echo ""
    
    for ((i=grace_seconds; i>=0; i--)); do
        local days=$((i / 86400))
        local hours=$(((i % 86400) / 3600))
        local minutes=$(((i % 3600) / 60))
        local seconds=$((i % 60))
        
        printf "\r${GREEN}Time remaining: %02d days, %02d:%02d:%02d${RESET}" "$days" "$hours" "$minutes" "$seconds"
        sleep 1
    done
    
    echo ""
    success "Grace period countdown complete!"
    exit 0
}

backup_and_remove() {
  local container=$1
  local dir=$2
  local domain
  domain=$(basename "$dir")
  local base=${domain%.*}

  if [[ "$DRY_RUN" == true ]]; then
      dry_run "Would archive and remove site for container '$container'..."
      dry_run "  - Would export database from '$container'..."
      dry_run "  - Would stop and remove container '$container'..."
      
      local stamp; stamp=$(date +%F_%H%M%S)
      local archive_path="${BACKUP_DIR}/${domain}_${stamp}.tgz"
      dry_run "  - Would archive '$dir' to '$archive_path'..."
      
      dry_run "  - Would drop MySQL database 'wp_$base' and user '$base'..."
      dry_run "  - Would remove site directory '$dir'..."
      dry_run "Site '$domain' would be backed up and removed."
  else
      info "Archiving and removing site for container '$container'..."
      mkdir -p "$BACKUP_DIR"

      info "  - Exporting database from '$container'..."
      docker exec "$container" rm -f wp-content/mysql.sql >/dev/null 2>&1 || true
      if ! docker exec "$container" wp db export wp-content/mysql.sql --allow-root >/dev/null 2>&1; then
          warn "  - Could not export database from '$container'. It might already be stopped. Proceeding with file backup."
      fi

      info "  - Stopping and removing container '$container'..."
      docker stop "$container" >/dev/null 2>&1 || true
      docker rm "$container" >/dev/null 2>&1 || true

      local stamp; stamp=$(date +%F_%H%M%S)
      local archive_path="${BACKUP_DIR}/${domain}_${stamp}.tgz"
      info "  - Archiving '$dir' to '$archive_path'..."
      tar --warning=no-file-changed --ignore-failed-read \
          -czf "$archive_path" -C "$(dirname "$dir")" "$domain" || true

      local mysql_pass=""
      [[ -f "$dir/.env" ]] && mysql_pass=$(grep -m1 '^MYSQL_PASS=' "$dir/.env" | cut -d= -f2-)
      mysql_pass=${mysql_pass:-${MYSQL_PASS-}}

      if [[ -n $mysql_pass ]] && docker exec mysql true 2>/dev/null; then
        info "  - Dropping MySQL database 'wp_$base' and user '$base'..."
        docker exec mysql mysql -p"$mysql_pass" -e "DROP DATABASE IF EXISTS wp_${base};" >/dev/null 2>&1 || true
        docker exec mysql mysql -p"$mysql_pass" -e "DROP USER IF EXISTS '${base}'@'%';" >/dev/null 2>&1 || true
      else
        warn "  - Skipping DB/user drop for '$domain' (no MySQL container or password found)."
      fi

      info "  - Removing site directory '$dir'..."
      rm -rf "$dir" || true

      success "Site '$domain' has been backed up and removed."
  fi
  
  ARCHIVED_SITES+=("$domain")
  ((ARCHIVED_COUNT++))
}

main() {
  if [[ "$DRY_RUN" == true ]]; then
      info "Starting cancellation cleanup job (DRY RUN MODE)..."
  else
      info "Starting cancellation cleanup job..."
  fi
  
  local cutoff_epoch
  cutoff_epoch=$(date -d "$GRACE_PERIOD_DAYS days ago" +%s)

  mapfile -t containers < <(docker ps --format '{{.Names}}' | grep '^wp_' || true)

  if [[ ${#containers[@]} -eq 0 ]]; then
      info "No running containers with 'wp_' prefix found."
  fi

  for container in "${containers[@]}"; do
      ((PROCESSED_COUNT++))
      info "-----------------------------------------------------"
      info "Processing container: $container"

      local work_dir
      work_dir=$(docker inspect "$container" 2>/dev/null | jq -r '.[0].Config.Labels."com.docker.compose.project.working_dir"')

      if [[ -z "$work_dir" || "$work_dir" == "null" ]]; then
          warn "Could not find working directory for '$container'. Skipping."
          ERROR_SITES+=("$container (no work_dir)")
          ((ERROR_COUNT++))
          continue
      fi

      local epoch_file="$work_dir/cancellation-epoch.txt"
      if [[ ! -f "$epoch_file" ]]; then
          info "No 'cancellation-epoch.txt' found for '$container' in '$work_dir'. Skipping."
          SKIPPED_SITES+=("$(basename "$work_dir") (no epoch file)")
          ((SKIPPED_COUNT++))
          continue
      fi

      local cancellation_epoch
      cancellation_epoch=$(cat "$epoch_file")

      if ! [[ "$cancellation_epoch" =~ ^[0-9]+$ ]]; then
          warn "Invalid content in '$epoch_file'. Expected an epoch timestamp. Skipping."
          ERROR_SITES+=("$(basename "$work_dir") (bad epoch file)")
          ((ERROR_COUNT++))
          continue
      fi

      local cancellation_date
      cancellation_date=$(date -d "@$cancellation_epoch" --iso-8601=seconds)
      info "Found cancellation timestamp: $cancellation_epoch ($cancellation_date)"

      if (( cancellation_epoch < cutoff_epoch )); then
          info "Cancellation for '$(basename "$work_dir")' is older than $GRACE_PERIOD_DAYS days. Proceeding with archival."
          backup_and_remove "$container" "$work_dir"
      else
          info "Cancellation for '$(basename "$work_dir")' is within the $GRACE_PERIOD_DAYS-day grace period. Skipping."
          SKIPPED_SITES+=("$(basename "$work_dir") (in grace period)")
          ((SKIPPED_COUNT++))
      fi
  done
}

print_summary() {
    local mode_text=""
    if [[ "$DRY_RUN" == true ]]; then
        mode_text=" (DRY RUN)"
    fi
    
    info "\n====================================================="
    info "                CLEANUP JOB SUMMARY${mode_text}"
    info "====================================================="
    info "Total containers processed: $PROCESSED_COUNT"
    
    if [[ "$DRY_RUN" == true ]]; then
        dry_run "Sites that would be archived and removed: $ARCHIVED_COUNT"
        if (( ARCHIVED_COUNT > 0 )); then
            for site in "${ARCHIVED_SITES[@]}"; do
                dry_run "  - $site"
            done
        fi
    else
        success "Sites archived and removed: $ARCHIVED_COUNT"
        if (( ARCHIVED_COUNT > 0 )); then
            for site in "${ARCHIVED_SITES[@]}"; do
                success "  - $site"
            done
        fi
    fi

    info "\nSites skipped: $SKIPPED_COUNT"
    if (( SKIPPED_COUNT > 0 )); then
        for site in "${SKIPPED_SITES[@]}"; do
            info "  - $site"
        done
    fi

    warn "\nErrors encountered: $ERROR_COUNT"
    if (( ERROR_COUNT > 0 )); then
        for site in "${ERROR_SITES[@]}"; do
            warn "  - $site"
        done
    fi
    info "====================================================="
}

# Trap to ensure summary is always printed, even on error
trap print_summary EXIT

# --- Main execution ---
if [[ "$TEST_GRACE_PERIOD" == true ]]; then
    test_grace_period_countdown
else
    main
fi