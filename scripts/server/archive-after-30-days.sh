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
set -auo pipefail

# --- Configuration ---
BACKUP_DIR="/var/opt/backups"
GRACE_PERIOD_DAYS=30

# Function to display help
show_help() {
  cat <<EOF
Usage: $0 [--test-grace-period] [--dry-run] [--grace-period=N] [--time-offset=HOURS] [--help]
Options:
  --test-grace-period    Interpret the grace period in seconds instead of days for testing.
  --dry-run              Perform a trial run without making changes.
  --grace-period=N       Set a custom grace period in days (or seconds if --test-grace-period).
  --time-offset=HOURS    Offset displayed timestamps by HOURS (default: -5 for EST).
  --help, -h             Display this help message and exit.
EOF
}

# --- Command line argument handling ---
TEST_GRACE_PERIOD=false
DRY_RUN=false
TIME_OFFSET_HOURS=-5

for arg in "$@"; do
  case $arg in
    --help|-h)
      show_help; exit 0;;
    --test-grace-period)
      TEST_GRACE_PERIOD=true; shift;;
    --dry-run)
      DRY_RUN=true; shift;;
    --grace-period=*)
      GRACE_PERIOD_DAYS="${arg#*=}"; shift;;
    --time-offset=*)
      TIME_OFFSET_HOURS="${arg#*=}"; shift;;
    *)
      error "Unknown argument: $arg"; show_help; exit 1;;
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

# <- Add this so sites_to_archive is always bound even under -u
sites_to_archive=()

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
      ARCHIVED_SITES+=("$domain")
      ((ARCHIVED_COUNT++))
  else
      info "Archiving and removing site for container '$container'..."
      if ! mkdir -p "$BACKUP_DIR"; then
        error "  - FAILED to create backup directory '$BACKUP_DIR'. Aborting for this site."
        ERROR_SITES+=("$domain (mkdir failed)")
        ((ERROR_COUNT++))
        return 1
      fi

      info "  - Exporting database from '$container'..."
      docker exec "$container" rm -f wp-content/mysql.sql >/dev/null 2>&1 || true
      if ! docker exec "$container" wp db export --allow-root >/dev/null 2>&1; then
          warn "  - Could not export database from '$container'. It might already be stopped. Proceeding with file backup."
      fi

      info "  - Stopping and removing container '$container'..."
      docker stop "$container" >/dev/null 2>&1 || true
      docker rm "$container" >/dev/null 2>&1 || true

      local stamp; stamp=$(date +%F_%H%M%S)
      local archive_path="${BACKUP_DIR}/${domain}_${stamp}.tgz"
      info "  - Archiving '$dir' to '$archive_path'..."
      tar --warning=no-file-changed --ignore-failed-read \
          --exclude '*backup*' \
          --exclude '*.zip' \
          --exclude '*.tar.gz' \
          --exclude '*.tgz' \
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
      ARCHIVED_SITES+=("$domain")
      ((ARCHIVED_COUNT++))
  fi
}

main() {
  if [[ "$DRY_RUN" == true ]]; then
    info "Starting cancellation cleanup job (DRY RUN MODE)…"
  else
    info "Starting cancellation cleanup job…"
  fi

  # decide cutoff based on normal or test mode
  local cutoff_epoch
  if [[ "$TEST_GRACE_PERIOD" == true ]]; then
    # In test mode, interpret GRACE_PERIOD_DAYS as seconds
    info "TEST MODE: Grace period is ${GRACE_PERIOD_DAYS} seconds."
    cutoff_epoch=$(( $(date +%s) - GRACE_PERIOD_DAYS ))
  else
    cutoff_epoch=$(date -d "$GRACE_PERIOD_DAYS days ago" +%s)
  fi

  mapfile -t all_containers < <(docker ps --format '{{.Names}}' | grep '^wp_' || true)

  if [[ ${#all_containers[@]} -eq 0 ]]; then
    info "No running containers with 'wp_' prefix found."
    return
  fi

  info "Scanning for sites eligible for archival..."
  for container in "${all_containers[@]}"; do
      local work_dir
      work_dir=$(docker inspect "$container" 2>/dev/null | jq -r '.[0].Config.Labels["com.docker.compose.project.working_dir"]')
      local epoch_file="$work_dir/cancellation-epoch.txt"

      if [[ -z "$work_dir" || ! -d "$work_dir" ]]; then
          SKIPPED_SITES+=("$container (work_dir not found)")
          continue
      fi

      if [[ ! -f "$epoch_file" ]]; then
          SKIPPED_SITES+=("$(basename "$work_dir") (no epoch file)")
          continue 
      fi

      if [[ "$TEST_GRACE_PERIOD" == true ]]; then
          # In test mode, any site with an epoch file is eligible
          sites_to_archive["$container"]="$work_dir"
      else
          # In normal mode, check the timestamp
          local cancellation_epoch
          cancellation_epoch=$(cat "$epoch_file")

          if [[ "$cancellation_epoch" =~ ^[0-9]+$ ]] && (( cancellation_epoch < cutoff_epoch )); then
              sites_to_archive["$container"]="$work_dir"
          else
              # Compute how much time remains under the grace period
              local now_epoch period_seconds expiration_epoch time_remaining
              now_epoch=$(date +%s)
              period_seconds=$(( GRACE_PERIOD_DAYS * 86400 ))
              expiration_epoch=$(( cancellation_epoch + period_seconds ))
              time_remaining=$(( expiration_epoch - now_epoch ))
              (( time_remaining < 0 )) && time_remaining=0

              # apply time-zone offset
              local offset_seconds=$(( TIME_OFFSET_HOURS * 3600 ))
              local expiration_local_epoch=$(( expiration_epoch + offset_seconds ))

              # breakdown remaining time
              local days hours minutes seconds
              days=$(( time_remaining / 86400 ))
              hours=$(( (time_remaining % 86400) / 3600 ))
              minutes=$(( (time_remaining % 3600) / 60 ))
              seconds=$(( time_remaining % 60 ))

              # format expiration date as US standard time
              local expiration_date
              expiration_date=$(date -d "@${expiration_local_epoch}" '+%m/%d/%Y %I:%M:%S %p')

              SKIPPED_SITES+=("$(basename "$work_dir") \
(in grace period: ${days}d ${hours}h ${minutes}m ${seconds}s remaining; \
estimated archival: ${expiration_date})")
          fi
      fi
  done
  
  SKIPPED_COUNT=${#SKIPPED_SITES[@]}

  # now this will always be safe:
  local archive_count=${#sites_to_archive[@]}

  if (( archive_count == 0 )); then
      info "No sites are currently eligible for archival."
      return
  fi

  # --- Confirmation Prompt ---
  info "\nThe following ${archive_count} site(s) are eligible for archival:"
  for container in "${!sites_to_archive[@]}"; do
      info "  - $(basename "${sites_to_archive[$container]}") (from container: $container)"
  done
  
  if [[ "$DRY_RUN" != true ]]; then
    echo
    read -p "Proceed with archiving these ${archive_count} site(s)? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      info "Operation cancelled by user."
      exit 0
    fi
    echo
  fi

  # --- Main Processing Loop ---
  # Now loop only through the sites we've confirmed for archival
  for container in "${!sites_to_archive[@]}"; do
      local work_dir=${sites_to_archive[$container]}
      ((PROCESSED_COUNT++))
      info "-----------------------------------------------------"
      info "Processing: $(basename "$work_dir")"
      backup_and_remove "$container" "$work_dir"
  done

  # Add skipped/error sites to the summary counts
  # ((SKIPPED_COUNT = ${#all_containers[@]} - PROCESSED_COUNT)) # This is now handled correctly above

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
main

set +auo pipefail