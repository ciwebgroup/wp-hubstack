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
set -auo pipefail

# source .env if it exists

SCRIPT_DIR=$(dirname "$0")
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  source "$SCRIPT_DIR/.env"
fi

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
OUTPUT_FILE=""; WRITE_MODE=""; DEBUG=""; REMOVE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output) [[ $# -lt 2 ]] && { echo "Missing arg for $1"; exit 1; }
                 OUTPUT_FILE=$2; shift 2 ;;
    --overwrite) WRITE_MODE=overwrite; shift ;;
    --append)    WRITE_MODE=append;   shift ;;
    -r|--remove) REMOVE=1;            shift ;;
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

##############################################################################
# .env load (auto‑export)
##############################################################################
SCRIPT_DIR=$(dirname "$0")
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a && source "$SCRIPT_DIR/.env" && set +a
fi
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
# Cloudflare ENV vars passed from client
NS1=${NS1:-}
NS2=${NS2:-}
CLOUDFLARE_EMAIL=${CLOUDFLARE_EMAIL:-}
CLOUDFLARE_API_KEY=${CLOUDFLARE_API_KEY:-}

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
  
  unset A_RECORDS
  declare -a A_RECORDS

  # Check NS records to decide lookup method
  mapfile -t NS_RECORDS < <(dig +short NS "$domain" || true)
  on_cloudflare=false
  if [[ -n "$NS1" && -n "$NS2" ]]; then
      ns1_found=false
      ns2_found=false
      for ns_record in "${NS_RECORDS[@]}"; do
          # dig output has a trailing dot
          [[ "${ns_record}" == "${NS1}." ]] && ns1_found=true
          [[ "${ns_record}" == "${NS2}." ]] && ns2_found=true
      done
      if $ns1_found && $ns2_found; then
          on_cloudflare=true
      fi
  fi

  if $on_cloudflare; then
      info "☁️  $domain is on Cloudflare, checking via API..."
      if ! command -v jq &>/dev/null; then
          warn "  ✗ 'jq' is not installed on remote. Cannot check Cloudflare domain."
      elif [[ -z "$CLOUDFLARE_EMAIL" || -z "$CLOUDFLARE_API_KEY" ]]; then
          warn "  ✗ CLOUDFLARE_EMAIL/API_KEY not set. Cannot check Cloudflare domain."
      else
          ZONE_RESPONSE=$(curl -s --request GET \
              --url "https://api.cloudflare.com/client/v4/zones?name=$domain" \
              --header "Content-Type: application/json" \
              --header "X-Auth-Email: ${CLOUDFLARE_EMAIL}" \
              --header "X-Auth-Key: ${CLOUDFLARE_API_KEY}")

          if [[ $(echo "$ZONE_RESPONSE" | jq -r '.success') != "true" ]]; then
              warn "  ✗ Cloudflare API error getting Zone ID for $domain"
          else
              ZONE_ID=$(echo "$ZONE_RESPONSE" | jq -r '.result[0].id')
              if [[ -z "$ZONE_ID" || "$ZONE_ID" == "null" ]]; then
                  warn "  ✗ Could not find Cloudflare Zone ID for $domain"
              else
                  RECORD_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$domain" \
                      -H "Content-Type: application/json" \
                      -H "X-Auth-Email: $CLOUDFLARE_EMAIL" \
                      -H "X-Auth-Key: $CLOUDFLARE_API_KEY")

                  if [[ $(echo "$RECORD_RESPONSE" | jq -r '.success') != "true" ]]; then
                      warn "  ✗ Cloudflare API error getting A records for $domain"
                  else
                      mapfile -t A_RECORDS < <(echo "$RECORD_RESPONSE" | jq -r '.result[].content')
                  fi
              fi
          fi
      fi
  else
      # Fallback to dig for non-Cloudflare domains
      mapfile -t A_RECORDS < <(dig +short A "$domain" || true)
  fi

  match=false
  for ip in "${A_RECORDS[@]}"; do
    [[ $ip == "$SERVER_IP" ]] && { match=true; break; }
  done

  if $match; then
    info "✓ $domain → on this server"
    echo "$domain,true"
  else
    warn "✗ $domain → NOT on this server (A=${A_RECORDS[*]:-none})"
    echo "$domain,false"
    if [[ -n $REMOVE ]]; then
      backup_and_remove "$domain" "$(dirname "$compose_file")" || true
    fi
  fi

done
REMOTE
##############################################################################

SSH_CMD=(ssh -T "$TARGET")
[[ -n $DEBUG ]] && SSH_CMD+=( -vvv )
REMOTE_PREFIX="bash -s -- $DOMAIN_PATH"
[[ -n $DEBUG ]] && REMOTE_PREFIX="REMOTE_DEBUG=1 $REMOTE_PREFIX -x"
[[ -n $REMOVE ]] && REMOTE_PREFIX="REMOVE=1 $REMOTE_PREFIX"
[[ -n ${MYSQL_PASS:-} ]] && REMOTE_PREFIX="MYSQL_PASS=$MYSQL_PASS $REMOTE_PREFIX"
[[ -n "${NS1:-}" ]] && REMOTE_PREFIX="NS1=$NS1 $REMOTE_PREFIX"
[[ -n "${NS2:-}" ]] && REMOTE_PREFIX="NS2=$NS2 $REMOTE_PREFIX"
[[ -n "${CLOUDFLARE_EMAIL:-}" ]] && REMOTE_PREFIX="CLOUDFLARE_EMAIL=$CLOUDFLARE_EMAIL $REMOTE_PREFIX"
[[ -n "${CLOUDFLARE_API_KEY:-}" ]] && REMOTE_PREFIX="CLOUDFLARE_API_KEY=$CLOUDFLARE_API_KEY $REMOTE_PREFIX"

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