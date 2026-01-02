#!/bin/bash

# A Record Retrieval Script
# This script retrieves A records for a specified domain from Cloudflare

# Display usage information
function display_help() {
    cat << EOF
Usage: $0 --url <domain.com> [--verbose] [--help]

This script retrieves A records for a specified domain from Cloudflare.

Required Parameters:
  --url <domain.com>    The domain name (e.g., example.com) to retrieve A records for

Optional Parameters:
  --verbose             Show detailed API responses and additional information
  --help                Display this help message and exit

Prerequisites:
 - The 'jq' utility must be installed (e.g., 'sudo apt-get install jq')
 - Valid Cloudflare credentials must be set in the script

Notes:
 - This script only retrieves A records (not CNAME, MX, etc.)
 - Shows current IP addresses and proxy status for each A record
EOF
    exit 0
}

# Load .env variables if they exist
# SCRIPT_DIR=$(dirname "$0")
# if [[ -f "$SCRIPT_DIR/.env.cf-keys" ]]; then
#   set -aeou pipefail && source "$SCRIPT_DIR/.env.cf-keys"
# fi

. .env.cf-keys

# Main function
function main() {
    URL=""
    VERBOSE=false
    ZONE_RESPONSE_PATH=""
    RECORD_RESPONSE_PATH=""
    IS_PROXIED_CHECK=false

    # Parse command line arguments
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --url)
                URL="$2"
                shift
                ;;
            --verbose)
                VERBOSE=true
                ;;
            --zone-response-path)
                ZONE_RESPONSE_PATH="$2"
                shift
                ;;
            --record-response-path)
                RECORD_RESPONSE_PATH="$2"
                shift
                ;;
            --is-proxied)
                IS_PROXIED_CHECK=true
                ;;
            --help)
                display_help
                ;;
            *)
                echo "Error: Unknown parameter passed: $1"
                display_help
                ;;
        esac
        shift
    done

    # Check prerequisites
    echo "▶ Verifying script prerequisites..."
    if ! command -v jq &> /dev/null; then
        echo "  Error: 'jq' is not installed. Please install it to continue." >&2
        exit 1
    fi
    if [[ -z "$CF_TOKEN" ]]; then
        echo "  Error: CF_TOKEN is not set in the script." >&2
        exit 1
    fi
    if [[ -z "$URL" ]]; then
        echo "  Error: The --url parameter is required." >&2
        display_help
        exit 1
    fi
    echo "✔ All checks passed."
    echo

    # Step 1: Get Zone ID
    echo "▶ Step 1: Fetching Zone ID for domain: $URL"
    ZONE_RESPONSE=$(curl -s --request GET \
        --url "https://api.cloudflare.com/client/v4/zones?name=$URL" \
        --header "Content-Type: application/json" \
        --header "Authorization: Bearer ${CF_TOKEN}")

    # Save ZONE_RESPONSE if requested
    if [[ -n "$ZONE_RESPONSE_PATH" ]]; then
        echo "$ZONE_RESPONSE" > "$ZONE_RESPONSE_PATH"
    fi

    if [[ "$VERBOSE" == "true" ]]; then
        echo "  📡 Zone API Response: $(echo "$ZONE_RESPONSE" | jq -c .)"
    fi

    # Check if the API call was successful
    if [[ $(echo "$ZONE_RESPONSE" | jq -r '.success') != "true" ]]; then
        echo "  ❌ Error: Failed to retrieve Zone ID for '$URL'." >&2
        if [[ "$VERBOSE" == "true" ]]; then
            echo "  📄 Full API Response: $(echo "$ZONE_RESPONSE" | jq .)" >&2
        fi
        exit 1
    fi

    ZONE_ID=$(echo "$ZONE_RESPONSE" | jq -r '.result[0].id')

    if [[ -z "$ZONE_ID" || "$ZONE_ID" == "null" ]]; then
        echo "  ❌ Error: Could not extract Zone ID from the API response for '$URL'." >&2
        echo "  💡 Please ensure the domain is associated with this Cloudflare account." >&2
        if [[ "$VERBOSE" == "true" ]]; then
            echo "  📄 API Response: $(echo "$ZONE_RESPONSE" | jq .)" >&2
        fi
        exit 1
    fi
    echo "✔ Successfully retrieved Zone ID: $ZONE_ID"
    echo

    # Step 2: Get A Records
    echo "▶ Step 2: Retrieving A records for '$URL'..."
    RECORD_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$URL" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $CF_TOKEN")

    # Save RECORD_RESPONSE if requested
    if [[ -n "$RECORD_RESPONSE_PATH" ]]; then
        echo "$RECORD_RESPONSE" > "$RECORD_RESPONSE_PATH"
    fi

    # If --is-proxied flag is set, check if any A record is proxied
    if [[ "$IS_PROXIED_CHECK" == "true" ]]; then
        proxied=$(echo "$RECORD_RESPONSE" | jq -r '.result[0].proxied')
        if [[ "$proxied" == "true" ]]; then
            exit 0
        else
            exit 1
        fi
    fi

    if [[ "$VERBOSE" == "true" ]]; then
        echo "  📡 DNS Records API Response: $(echo "$RECORD_RESPONSE" | jq -c .)"
    fi

    # Check if the API call was successful
    if [[ $(echo "$RECORD_RESPONSE" | jq -r '.success') != "true" ]]; then
        echo "  ❌ Error: Failed to retrieve DNS records for '$URL'." >&2
        if [[ "$VERBOSE" == "true" ]]; then
            echo "  📄 Full API Response: $(echo "$RECORD_RESPONSE" | jq .)" >&2
        fi
        exit 1
    fi

    # Parse and display A records
    RECORD_COUNT=$(echo "$RECORD_RESPONSE" | jq '.result | length')
    
    if [[ "$RECORD_COUNT" -eq 0 ]]; then
        echo "  ⚠️  No A records found for '$URL'"
        echo "  💡 The domain may only have CNAME records or other record types"
        exit 1
    else
        echo "✔ Found $RECORD_COUNT A record(s) for '$URL':"
        echo
        
        # Display each A record
        for i in $(seq 0 $((RECORD_COUNT - 1))); do
            RECORD_ID=$(echo "$RECORD_RESPONSE" | jq -r ".result[$i].id")
            RECORD_NAME=$(echo "$RECORD_RESPONSE" | jq -r ".result[$i].name")
            RECORD_CONTENT=$(echo "$RECORD_RESPONSE" | jq -r ".result[$i].content")
            RECORD_PROXIED=$(echo "$RECORD_RESPONSE" | jq -r ".result[$i].proxied")
            RECORD_TTL=$(echo "$RECORD_RESPONSE" | jq -r ".result[$i].ttl")
            
            echo "  📍 A Record #$((i + 1)):"
            echo "     Name: $RECORD_NAME"
            echo "     IP Address: $RECORD_CONTENT"
            echo "     Proxied: $RECORD_PROXIED"
            echo "     TTL: $RECORD_TTL"
            if [[ "$VERBOSE" == "true" ]]; then
                echo "     Record ID: $RECORD_ID"
            fi
            echo
        done
    fi

    echo "--- Summary ---"
    echo "Domain: $URL"
    echo "Zone ID: $ZONE_ID"
    echo "A Records Found: $RECORD_COUNT"
    
    if [[ "$VERBOSE" == "true" ]]; then
        echo
        echo "📄 Complete DNS Records Response:"
        echo "$RECORD_RESPONSE" | jq .
    fi

    exit 0
}

# Run the main function with all script arguments
main "$@"

set -aeuo pipefail