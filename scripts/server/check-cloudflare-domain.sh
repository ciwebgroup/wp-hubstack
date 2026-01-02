#!/usr/bin/env bash
set -euo pipefail

# Checks if a domain is on Cloudflare and if its A record points to a given IP.
#
# Exits:
# 0: Domain on Cloudflare, A record matches server IP.
# 1: Domain on Cloudflare, A record does NOT match server IP.
# 2: Domain is NOT on Cloudflare.
# 3: Prerequisite missing (jq, credentials) or Cloudflare API error.

[[ $# -ne 2 ]] && { echo "Usage: $0 <domain> <server_ip>" >&2; exit 3; }
DOMAIN=$1
SERVER_IP=$2

# Load .env from the script's directory
SCRIPT_DIR=$(dirname "$0")
if [[ -f "$SCRIPT_DIR/.env.cf-keys" ]]; then
  source "$SCRIPT_DIR/.env.cf-keys"
fi

# --- Prerequisite Checks ---
if ! command -v jq &>/dev/null; then
    echo "Error: 'jq' is not installed." >&2
    exit 3
fi
if [[ -z "${CF_TOKEN:-}" || -z "${NS1:-}" || -z "${NS2:-}" ]]; then
    echo "Error: CF_TOKEN or NS not set in .env" >&2
    exit 3
fi

# --- Check if domain is on Cloudflare via NS records ---
mapfile -t NS_RECORDS < <(dig +short NS "$DOMAIN" || true)
ns1_found=false
ns2_found=false
for ns_record in "${NS_RECORDS[@]}"; do
    [[ "${ns_record}" == "${NS1}." ]] && ns1_found=true
    [[ "${ns_record}" == "${NS2}." ]] && ns2_found=true
done

if ! ($ns1_found && $ns2_found); then
    exit 2 # Not on Cloudflare
fi

# --- On Cloudflare, so check A record via API ---
ZONE_RESPONSE=$(curl -s --request GET \
    --url "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
    --header "Content-Type: application/json" \
    --header "Authorization: Bearer ${CF_TOKEN}")

if [[ $(echo "$ZONE_RESPONSE" | jq -r '.success') != "true" ]]; then
    echo "Error: Cloudflare API error getting Zone ID for $DOMAIN" >&2
    exit 3
fi

ZONE_ID=$(echo "$ZONE_RESPONSE" | jq -r '.result[0].id')
if [[ -z "$ZONE_ID" || "$ZONE_ID" == "null" ]]; then
    echo "Error: Could not find Cloudflare Zone ID for $DOMAIN" >&2
    exit 3
fi

RECORD_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$DOMAIN" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $CF_TOKEN")

if [[ $(echo "$RECORD_RESPONSE" | jq -r '.success') != "true" ]]; then
    echo "Error: Cloudflare API error getting A records for $DOMAIN" >&2
    exit 3
fi

mapfile -t A_RECORDS < <(echo "$RECORD_RESPONSE" | jq -r '.result[].content')

for ip in "${A_RECORDS[@]}"; do
  if [[ $ip == "$SERVER_IP" ]]; then
    exit 0 # Match found
  fi
done

exit 1 # No match found