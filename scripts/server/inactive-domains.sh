#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# remote-domain-on-server-check.sh  –  verify that each site's domain resolves
# to the public IP of the server it lives on. Optionally back‑up and remove
# sites whose DNS does **not** point at this server.
# ---------------------------------------------------------------------------
# Features
#   • Scans DOMAIN_PATH (default /var/opt) for */docker-compose.yml that contain
#     at least one wp_* service (skips infra stacks like mysql, redis, traefik).
#   • Determines server's public IPv4 (dig +short myip.opendns.com …)
#   • For each domain, does "dig +short A <domain>" (timeout inherent to dig)
#   • Reports colourised status to stderr; optional CSV to a file.
#   • Flags:  -o/--output FILE, --overwrite, --append, -r/--remove,
#             -d/--debug, -h/--help
# ---------------------------------------------------------------------------
set -uo pipefail

##############################################################################
# Help / usage
##############################################################################
usage() {
  cat <<'EOF'
remote-domain-on-server-check.sh – list domains whose DNS A‑record does NOT
resolve to this server's public IP and, optionally, remove them.

USAGE
  remote-domain-on-server-check.sh [options] [user@]host

POSITIONAL ARGUMENTS
  host                 Target "host" (assumes root@) or "user@host"

OPTIONS
  -o, --output FILE    Write CSV results (domain,true|false) to FILE
      --overwrite      Overwrite FILE without prompting
      --append         Append to FILE without prompting
  -r, --remove         Backup **and** delete sites that are *not* on this server
      --dry-run        Show what would be backed up and removed without making changes.
  -d, --debug          Verbose: ssh -vvv + remote bash -x
  -h, --help           Show this help and exit.

NOTES
  • DOMAIN_PATH defaults to /var/opt but can be set in a peer .env file.
  • Colour logs always go to stderr; CSV never shows on screen unless -o used.
EOF
}

##############################################################################
# Option parsing
##############################################################################
OUTPUT_FILE=""; WRITE_MODE=""; DEBUG=""; REMOVE=""; DRY_RUN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output) [[ $# -lt 2 ]] && { echo "Missing arg for $1"; exit 1; }
                 OUTPUT_FILE=$2; shift 2 ;;
    --overwrite) WRITE_MODE=overwrite; shift ;;
    --append)    WRITE_MODE=append;   shift ;;
    -r|--remove) REMOVE=1;            shift ;;
    --dry-run)   DRY_RUN=1;           shift ;;
    -d|--debug)  DEBUG=1;             shift ;;
    -h|--help)   usage; exit 0 ;;
    --)          shift; break ;;
    -*)          echo "Unknown option $1"; usage; exit 1 ;;
    *)           break ;;
  esac
done

[[ $# -ne 1 ]] && { echo "Need remote host"; usage; exit 1; }
TARGET=$1
[[ $TARGET != *@* ]] && TARGET="root@$TARGET"

DOMAIN_PATH=${DOMAIN_PATH:-/var/opt}

##############################################################################
# Output file validation & prompt
##############################################################################
if [[ -n $OUTPUT_FILE ]]; then
  OUTDIR=$(dirname "$OUTPUT_FILE")
  [[ -d $OUTDIR && -w $OUTDIR ]] || { echo "Cannot write to $OUTPUT_FILE"; exit 1; }

  if [[ -e $OUTPUT_FILE && -z $WRITE_MODE ]]; then
    read -rp "Overwrite (O) or Append (A) [O]: " ans
    [[ ${ans^^} == A* ]] && WRITE_MODE=append || WRITE_MODE=overwrite
  fi
  [[ -z $WRITE_MODE ]] && WRITE_MODE=overwrite
fi

##############################################################################
# Remote script content (heredoc)
##############################################################################
read -r -d '' REMOTE_SH <<'REMOTE'
#!/usr/bin/env bash
set -euo pipefail
[[ -n ${REMOTE_DEBUG:-} ]] && set -x

DOMAIN_PATH=$1
REMOVE=${REMOVE:-}
DRY_RUN=${DRY_RUN:-}
CLOUDFLARE_CHECKER_SCRIPT="check-cloudflare-domain.sh"

SERVER_IP=$(dig +short myip.opendns.com @resolver1.opendns.com | head -n1 | tr -d '\r')
[[ -z $SERVER_IP ]] && { echo "Could not determine remote public IP" >&2; exit 1; }

GREEN='\e[32m'; YELLOW='\e[33m'; RESET='\e[0m'
info(){ echo -e "${GREEN}$*${RESET}" >&2; }
warn(){ echo -e "${YELLOW}$*${RESET}" >&2; }

backup_and_remove(){
  local domain=$1
  local dir=$2
  local base=${domain%.*}
  local container="wp_${base}"

  if [[ -n $DRY_RUN ]]; then
    info "[DRY RUN] Would backup and remove '$domain'"
    info "[DRY RUN]   - Target directory: $dir"
    info "[DRY RUN]   - Container: $container"
    info "[DRY RUN]   - Would check for container '$container'..."
    info "[DRY RUN]   - Would run: docker exec $container rm -f wp-content/mysql.sql"
    info "[DRY RUN]   - Would run: docker exec $container wp db export wp-content/mysql.sql --allow-root"
    info "[DRY RUN]   - Would run: docker stop $container"
    info "[DRY RUN]   - Would run: docker rm $container"
    local stamp; stamp=$(date +%F_%H%M%S)
    info "[DRY RUN]   - Would archive '$dir' to '/var/opt/backups/${domain}_${stamp}.tgz'"
    local mysql_pass=""
    [[ -f "$dir/.env" ]] && mysql_pass=$(grep -m1 '^MYSQL_PASS=' "$dir/.env" | cut -d= -f2-)
    mysql_pass=${mysql_pass:-${MYSQL_PASS-}}
    if [[ -n $mysql_pass ]]; then
        info "[DRY RUN]   - Would run: docker exec mysql mysql -p'...' -e 'DROP DATABASE IF EXISTS wp_${base};'"
        info "[DRY RUN]   - Would run: docker exec mysql mysql -p'...' -e 'DROP USER IF EXISTS \'${base}\'@\'%\';'"
    else
        info "[DRY RUN]   - Would skip DB/user drop (no password found)."
    fi
    info "[DRY RUN]   - Would run: rm -rf $dir"
    return
  fi

  mkdir -p /var/opt/backups

  if docker inspect --type container "$container" &>/dev/null; then
    docker exec "$container" rm -f wp-content/mysql.sql  >/dev/null 2>&1 || true
    docker exec "$container" wp db export wp-content/mysql.sql --allow-root >/dev/null 2>&1 || true
    docker stop "$container" >/dev/null 2>&1 || true
    docker rm   "$container" >/dev/null 2>&1 || true
  else
    warn "Container $container not found – skipping container steps."
  fi

  local stamp; stamp=$(date +%F_%H%M%S)
  # tolerate changed files during archiving
  tar --warning=no-file-changed --ignore-failed-read -czf "/var/opt/backups/${domain}_${stamp}.tgz" -C /var/opt "$domain" || true

  local mysql_pass=""
  [[ -f "$dir/.env" ]] && mysql_pass=$(grep -m1 '^MYSQL_PASS=' "$dir/.env" | cut -d= -f2-)
  mysql_pass=${mysql_pass:-${MYSQL_PASS-}}

  if [[ -n $mysql_pass ]] && docker exec mysql true 2>/dev/null; then
    docker exec mysql mysql -p"$mysql_pass" -e "DROP DATABASE IF EXISTS wp_${base};" >/dev/null 2>&1 || true
    docker exec mysql mysql -p"$mysql_pass" -e "DROP USER IF EXISTS '${base}'@'%';"   >/dev/null 2>&1 || true
  else
    warn "Skipping DB/user drop for $domain (no MySQL or password)."
  fi

  rm -rf "$dir" || true
  info "✅  $domain backed‑up and removed (or already absent)."
}

info "Server public IP: $SERVER_IP"

for compose_file in "${DOMAIN_PATH}"/*/docker-compose.yml; do
  [[ ! -f $compose_file ]] && continue

  wp_services=$(docker compose -f "$compose_file" config --services | grep -E '^wp_' || true)
  [[ -z $wp_services ]] && continue

  domain=$(basename "$(dirname "$compose_file")")
  if [[ -n $DRY_RUN ]]; then
      info "[DRY RUN] Checking domain: $domain"
  fi
  
  match=false
  a_records_str="none"
  processed_by_cf=false

  # Check via Cloudflare script first, if it's executable and in the PATH
  if command -v "$CLOUDFLARE_CHECKER_SCRIPT" &>/dev/null; then
      if [[ -n $DRY_RUN ]]; then info "[DRY RUN]   Cloudflare checker script found, executing..."; fi
      
      cf_exit_status=0
      # Suppress checker's output and handle non-zero exit codes gracefully
      "$CLOUDFLARE_CHECKER_SCRIPT" "$domain" "$SERVER_IP" >/dev/null 2>&1 || cf_exit_status=$?

      case $cf_exit_status in
        0) # On CF, A record matches
          match=true
          processed_by_cf=true
          ;;
        1) # On CF, A record does NOT match
          match=false
          a_records_str="Cloudflare (mismatch)"
          processed_by_cf=true
          ;;
        3) # Prerequisite/API error from checker
          warn "  ✗ Cloudflare check for '$domain' failed (see errors from helper script). Falling back to dig."
          ;;
        # Case 2 (Not on CF) will fall through to the dig check below
      esac
  fi

  # If not processed by the Cloudflare script, fall back to dig
  if ! $processed_by_cf; then
      if [[ -n $DRY_RUN ]]; then info "[DRY RUN]   Using 'dig' for A records."; fi
      mapfile -t A_RECORDS < <(dig +short A "$domain" || true)
      a_records_str="${A_RECORDS[*]:-none}"
      for ip in "${A_RECORDS[@]}"; do
        if [[ $ip == "$SERVER_IP" ]]; then
          match=true
          break
        fi
      done
  fi

  if $match; then
    info "✓ $domain → on this server"
    echo "$domain,true"
  else
    warn "✗ $domain → NOT on this server (A=${a_records_str})"
    echo "$domain,false"
    if [[ -n $REMOVE || -n $DRY_RUN ]]; then
      backup_and_remove "$domain" "$(dirname "$compose_file")" || true
    fi
  fi

done
REMOTE
##############################################################################

SSH_CMD=(ssh -T "$TARGET")
[[ -n $DEBUG ]] && SSH_CMD+=( -vvv )

declare -a remote_env_vars
[[ -n $DEBUG ]] && remote_env_vars+=("REMOTE_DEBUG=1")
[[ -n $REMOVE ]] && remote_env_vars+=("REMOVE=1")
[[ -n $DRY_RUN ]] && remote_env_vars+=("DRY_RUN=1")
[[ -n "${MYSQL_PASS:-}" ]] && remote_env_vars+=("MYSQL_PASS=$(printf '%q' "$MYSQL_PASS")")

REMOTE_PREFIX="${remote_env_vars[*]} bash -s -- $DOMAIN_PATH"

if [[ -n $OUTPUT_FILE ]]; then
  csv=$( "${SSH_CMD[@]}" "$REMOTE_PREFIX" 2> >(cat >&2) <<REMOTE_EOF
$REMOTE_SH
REMOTE_EOF
  )
else
  "${SSH_CMD[@]}" "$REMOTE_PREFIX" >/dev/null <<REMOTE_EOF
$REMOTE_SH
REMOTE_EOF
  exit
fi

if [[ $WRITE_MODE == overwrite ]]; then
  printf '%s\n' "$csv" >  "$OUTPUT_FILE"
else
  printf '%s\n' "$csv" >> "$OUTPUT_FILE"
fi

echo "CSV results written to $OUTPUT_FILE"

set +aou pipefail

exit 0