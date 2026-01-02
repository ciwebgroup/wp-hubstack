#!/bin/bash

# #############################################################################
# Cloudflare SSL/TLS Validation Script
#
# This script automates the process of updating the SSL validation method for a
# domain (zone) in Cloudflare. It performs three main actions:
#
# 1. GET Zone ID: Fetches the Zone ID for a given domain name (URL).
# 2. GET SSL Verification: Fetches SSL verification details to retrieve the
#    'cert_pack_uuid' for the zone's certificate pack.
# 3. PATCH Request: Submits the retrieved 'cert_pack_uuid' to update the
#    validation method to 'txt'.
#
# It requires jq to be installed for parsing JSON responses.
# #############################################################################

# --- Configuration ---
# Your Cloudflare credentials should be set as environment variables.
# Example:
# export CLOUDFLARE_EMAIL="user@example.com"
# export CLOUDFLARE_API_KEY="your_global_api_key"

# --- Script Functions ---

CLOUDFLARE_EMAIL="support@ciwebgroup.com"
CLOUDFLARE_API_KEY="3852e5e2de4bf9a6a64eef0a6da8cc4e0591c"


# Displays usage information and exits.
function display_help() {
    cat << EOF
Usage: $0 --url <domain.com> [--dry-run [mode]] [--help]

This script updates the SSL validation method for a given Cloudflare zone.

Required Parameters:
  --url <domain.com>    The domain name (e.g., example.com) you are targeting.

Optional Parameters:
  --dry-run [mode]      Inspect the API calls without executing them.
                        Modes:
                        - full (default): Prevents all API calls. Shows what
                          would be run for all GET and PATCH requests.
                        - on-validate: Performs the initial GET requests but
                          stops before sending the final PATCH validation request.
  --help                Display this help message and exit.

Prerequisites:
 - The 'jq' utility must be installed (e.g., 'sudo apt-get install jq').
 - The following environment variables must be set:
   - CLOUDFLARE_EMAIL
   - CLOUDFLARE_API_KEY
EOF
    exit 0
}

# --- Main Logic ---

function main() {

    # If CLOUDFLARE_EMAIL or CLOUDFLARE_API_KEY are not set, exit with an error.
    if [[ -z "$CLOUDFLARE_EMAIL" || -z "$CLOUDFLARE_API_KEY" ]]; then
        echo "Error: CLOUDFLARE_EMAIL and CLOUDFLARE_API_KEY environment variables must be set." >&2
        exit 1
    fi

    # --- Parameter Parsing ---
    URL=""
    DRY_RUN_MODE="" # Can be "full" or "on-validate"

    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --url)
                URL="$2"
                shift
                ;;
            --dry-run)
                # Allows for --dry-run with or without an argument
                case "$2" in
                    ""|--*) DRY_RUN_MODE="full" ;;
                    *) DRY_RUN_MODE="$2"; shift ;;
                esac
                ;;
            --help)
                display_help
                ;;
            *)
                echo "Error: Unknown parameter passed: $1"
                display_help
                exit 1
                ;;
        esac
        shift
    done

    # --- Variable Validation ---
    echo "▶ Verifying script prerequisites..."
    if ! command -v jq &> /dev/null; then
        echo "  Error: 'jq' is not installed. Please install it to continue." >&2
        exit 1
    fi
    if [[ -z "$CLOUDFLARE_EMAIL" ]]; then
        echo "  Error: Environment variable CLOUDFLARE_EMAIL is not set." >&2
        exit 1
    fi
    if [[ -z "$CLOUDFLARE_API_KEY" ]]; then
        echo "  Error: Environment variable CLOUDFLARE_API_KEY is not set." >&2
        exit 1
    fi
    if [[ -z "$URL" ]]; then
        echo "  Error: The --url parameter is required." >&2
        display_help
        exit 1
    fi
    echo "✔ All checks passed."
    echo

    # --- Step 1: Get Zone ID from URL ---
    echo "▶ Step 1: Fetching Zone ID for URL: $URL"
    ZONE_ID_API_URL="https://api.cloudflare.com/client/v4/zones?name=$URL"
    ZONE_ID=""

    if [[ "$DRY_RUN_MODE" == "full" ]]; then
        echo "  DRY RUN (full): The following GET request would be sent to fetch the Zone ID:"
        cat <<EOF
    curl -s -X GET "$ZONE_ID_API_URL" \\
         -H "Content-Type: application/json" \\
         -H "X-Auth-Email: $CLOUDFLARE_EMAIL" \\
         -H "X-Auth-Key: $CLOUDFLARE_API_KEY"
EOF
        # In a full dry run, we must exit as subsequent steps depend on the ZONE_ID.
        echo
        echo "Dry run complete. No requests were sent."
        exit 0
    fi

    # Execute the request to get the Zone ID
    ZONE_RESPONSE=$(curl -s -X GET "$ZONE_ID_API_URL" \
        -H "Content-Type: application/json" \
        -H "X-Auth-Email: $CLOUDFLARE_EMAIL" \
        -H "X-Auth-Key: $CLOUDFLARE_API_KEY")

    if [[ $(echo "$ZONE_RESPONSE" | jq -r '.success') != "true" ]]; then
        echo "  Error: Failed to retrieve Zone ID for '$URL'." >&2
        echo "  API Response: $(echo "$ZONE_RESPONSE" | jq .)" >&2
        exit 1
    fi

    ZONE_ID=$(echo "$ZONE_RESPONSE" | jq -r '.result[0].id')

    if [[ -z "$ZONE_ID" || "$ZONE_ID" == "null" ]]; then
        echo "  Error: Could not extract Zone ID from the API response for '$URL'." >&2
        echo "  Please ensure the domain is associated with this Cloudflare account." >&2
        echo "  API Response: $(echo "$ZONE_RESPONSE" | jq .)" >&2
        exit 1
    fi
    echo "✔ Successfully retrieved Zone ID: $ZONE_ID"
    echo

    # --- Step 2: Get SSL Verification Details ---
    echo "▶ Step 2: Fetching SSL verification details for Zone ID: $ZONE_ID"
    GET_API_URL="https://api.cloudflare.com/client/v4/zones/$ZONE_ID/ssl/verification"
    CERTIFICATE_PACK_ID=""

    # This step is skipped in a 'full' dry-run, but executed in an 'on-validate' dry-run.
    RESPONSE=$(curl -s -X GET "$GET_API_URL" \
        -H "Content-Type: application/json" \
        -H "X-Auth-Email: $CLOUDFLARE_EMAIL" \
        -H "X-Auth-Key: $CLOUDFLARE_API_KEY")

    if [[ $(echo "$RESPONSE" | jq -r '.success') != "true" ]]; then
        echo "  Error: Failed to retrieve SSL verification details." >&2
        echo "  API Response: $(echo "$RESPONSE" | jq .)" >&2
        exit 1
    fi

    CERTIFICATE_PACK_ID=$(echo "$RESPONSE" | jq -r '.result[0].cert_pack_uuid')

    if [[ -z "$CERTIFICATE_PACK_ID" || "$CERTIFICATE_PACK_ID" == "null" ]]; then
        echo "  Error: Could not extract 'cert_pack_uuid' from the API response." >&2
        echo "  API Response: $(echo "$RESPONSE" | jq .)" >&2
        exit 1
    fi
    echo "✔ Successfully retrieved Certificate Pack ID: $CERTIFICATE_PACK_ID"
    echo

    # --- Step 3: Update SSL Validation Method ---
    echo "▶ Step 3: Updating validation method to 'txt'"
    PATCH_API_URL="https://api.cloudflare.com/client/v4/zones/$ZONE_ID/ssl/verification/$CERTIFICATE_PACK_ID"
    PATCH_PAYLOAD='{"validation_method": "txt"}'

    if [[ "$DRY_RUN_MODE" == "on-validate" ]]; then
        echo "  DRY RUN (on-validate): The following PATCH request would be sent:"
        cat <<EOF
    curl -s -X PATCH "$PATCH_API_URL" \\
         -H "Content-Type: application/json" \\
         -H "X-Auth-Email: $CLOUDFLARE_EMAIL" \\
         -H "X-Auth-Key: $CLOUDFLARE_API_KEY" \\
         -d '$PATCH_PAYLOAD'
EOF
        echo
        echo "Dry run complete. The final validation request was not sent."
        exit 0
    fi

    # Execute the PATCH request
    echo "  Sending PATCH request to update validation method..."
    PATCH_RESPONSE=$(curl -s -X PATCH "$PATCH_API_URL" \
        -H "Content-Type: application/json" \
        -H "X-Auth-Email: $CLOUDFLARE_EMAIL" \
        -H "X-Auth-Key: $CLOUDFLARE_API_KEY" \
        -d "$PATCH_PAYLOAD")

    if [[ $(echo "$PATCH_RESPONSE" | jq -r '.success') != "true" ]]; then
        echo "  Error: Failed to update the validation method." >&2
        echo "  API Response: $(echo "$PATCH_RESPONSE" | jq .)" >&2
        exit 1
    fi

    echo "✔ Successfully updated validation method."
    echo
    echo "--- Process Complete ---"
    echo "Final API Response:"
    echo "$PATCH_RESPONSE" | jq .
}

# Run the main function with all script arguments
main "$@"
