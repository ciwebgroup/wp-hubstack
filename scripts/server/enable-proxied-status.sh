#!/bin/bash

# Cloudflare DNS Record Selective Proxy Script
# This script selectively enables/disables proxying for A and CNAME records based on subdomain rules

. .env.cf-keys

# Display usage information
function display_help() {
    cat << EOF
Usage: $0 --url <domain.com> [--dry-run] [--verbose] [--force] [--help]

This script retrieves A and CNAME records for a specified domain and actively manages
Cloudflare proxy settings based on record type and subdomain rules.

Required Parameters:
  --url <domain.com>    The domain name (e.g., example.com) to update

Optional Parameters:
  --dry-run             Show what changes would be made without executing them
  --verbose             Show detailed API responses and additional information
  --force               Force update all records, even if they appear to be already proxied
  --help                Display this help message and exit

Prerequisites:
 - The 'jq' utility must be installed (e.g., 'sudo apt-get install jq')
 - Valid Cloudflare credentials must be set in the script

Excluded Domains:
 - ciwebgroup.com: Protected domain that will not be modified

Proxying Rules:
 - A records for root domain: Proxied (proxied=true)
 - A records for subdomains: Actively unproxied (proxied=false)
 - CNAME records for root domain and www subdomain: Proxied (proxied=true)
 - CNAME records for other subdomains: Actively unproxied (proxied=false)
 - Preserves existing IP addresses and TTL values
EOF
    exit 0
}

# Function to process DNS records of a specific type
function process_dns_records() {
    local ZONE_ID="$1"
    local URL="$2"
    local RECORD_TYPE="$3"
    local DRY_RUN="$4"
    local VERBOSE="$5"
    local FORCE="$6"
    
    echo "▶ Retrieving $RECORD_TYPE records for '$URL' (including subdomains)..." >&2
    
    local RECORD_RESPONSE

    if [[ -z "$CF_TOKEN" ]]; then
        echo "  ❌ Error: Cloudflare API Token (CF_TOKEN) is not set." >&2
        return 1
    fi
    
    RECORD_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=$RECORD_TYPE" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $CF_TOKEN")

    if [[ "$VERBOSE" == "true" ]]; then
        echo "  📡 $RECORD_TYPE Records API Response: $(echo "$RECORD_RESPONSE" | jq -c .)" >&2
    fi

    # Check if the API call was successful
    if [[ $(echo "$RECORD_RESPONSE" | jq -r '.success') != "true" ]]; then
        echo "  ❌ Error: Failed to retrieve $RECORD_TYPE records for '$URL'." >&2
        if [[ "$VERBOSE" == "true" ]]; then
            echo "  📄 Full API Response: $(echo "$RECORD_RESPONSE" | jq .)" >&2
        fi
        return 1
    fi

    local RECORD_COUNT
    
    RECORD_COUNT=$(echo "$RECORD_RESPONSE" | jq '.result | length')
    
    if [[ "$RECORD_COUNT" -eq 0 ]]; then
        echo "  ℹ️  No $RECORD_TYPE records found for '$URL'" >&2
        echo "0 0 0 0"  # Return: total_count updated_count already_proxied_count skipped_count
        return 0
    fi

    echo "✔ Found $RECORD_COUNT $RECORD_TYPE record(s) for '$URL'" >&2
    
    # Process each record
    local UPDATED_COUNT=0
    local ALREADY_PROXIED_COUNT=0
    local SKIPPED_COUNT=0

    for i in $(seq 0 $((RECORD_COUNT - 1))); do
        local RECORD_ID
        RECORD_ID=$(echo "$RECORD_RESPONSE" | jq -r ".result[$i].id")
        local RECORD_NAME
        RECORD_NAME=$(echo "$RECORD_RESPONSE" | jq -r ".result[$i].name")
        local RECORD_CONTENT
        RECORD_CONTENT=$(echo "$RECORD_RESPONSE" | jq -r ".result[$i].content")
        local RECORD_PROXIED
        RECORD_PROXIED=$(echo "$RECORD_RESPONSE" | jq -r ".result[$i].proxied")
        local RECORD_TTL
        RECORD_TTL=$(echo "$RECORD_RESPONSE" | jq -r ".result[$i].ttl")
        
        echo "  📍 Processing $RECORD_TYPE Record #$((i + 1)):" >&2
        echo "     Name: $RECORD_NAME" >&2
        if [[ "$RECORD_TYPE" == "A" ]]; then
            echo "     IP Address: $RECORD_CONTENT" >&2
        else
            echo "     Target: $RECORD_CONTENT" >&2
        fi
        echo "     Current Proxied Status: $RECORD_PROXIED" >&2
        echo "     TTL: $RECORD_TTL" >&2
        
        # Determine if this record should be proxied based on type and subdomain
        local SHOULD_PROXY=""  # Can be "true", "false", or empty (skip)
        if [[ "$RECORD_TYPE" == "A" ]]; then
            # Only proxy A records for root domain, unproxy all subdomain A records
            if [[ "$RECORD_NAME" == "$URL" ]]; then
                SHOULD_PROXY="true"
                echo "     📋 Rule: A record for root domain - will be proxied" >&2
            else
                SHOULD_PROXY="false"
                echo "     📋 Rule: A record for subdomain - will be UNPROXIED" >&2
            fi
        elif [[ "$RECORD_TYPE" == "CNAME" ]]; then
            # Only proxy CNAME records for www subdomain
            if [[ "$RECORD_NAME" == "www.$URL" ]]; then
                SHOULD_PROXY="true"
                echo "     📋 Rule: CNAME for www subdomain - will be proxied" >&2
            else
                SHOULD_PROXY="false"
                echo "     📋 Rule: CNAME for other subdomain - will be UNPROXIED" >&2
            fi
        fi
        
        if [[ "$SHOULD_PROXY" == "false" ]]; then
            # Need to disable proxy for this record
            echo "     🔄 Needs to be unproxied (set to proxied=false)" >&2
            
            if [[ "$DRY_RUN" == "true" ]]; then
                echo "     🔍 DRY RUN: Would update this record to proxied=false" >&2
                cat <<EOF >&2
         curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \\
              -H "Content-Type: application/json" \\
              -H "Authorization: Bearer \$CF_TOKEN" \\
              --data '{"type":"$RECORD_TYPE","name":"$RECORD_NAME","content":"$RECORD_CONTENT","ttl":$RECORD_TTL,"proxied":false}'
EOF
                UPDATED_COUNT=$((UPDATED_COUNT + 1))
            else
                local UPDATE_RESPONSE
                echo "     📡 Updating record to disable proxy..." >&2
                UPDATE_RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
                    -H "Content-Type: application/json" \
                    -H "Authorization: Bearer $CF_TOKEN" \
                    --data "{\"type\":\"$RECORD_TYPE\",\"name\":\"$RECORD_NAME\",\"content\":\"$RECORD_CONTENT\",\"ttl\":$RECORD_TTL,\"proxied\":false}")

                if [[ "$VERBOSE" == "true" ]]; then
                    echo "     📡 Update API Response: $(echo "$UPDATE_RESPONSE" | jq -c .)" >&2
                fi

                # Check if the update was successful
                if [[ $(echo "$UPDATE_RESPONSE" | jq -r '.success') == "true" ]]; then
                    echo "     ✅ Successfully disabled proxy for this record" >&2
                    UPDATED_COUNT=$((UPDATED_COUNT + 1))
                else
                    echo "     ❌ Failed to update this record" >&2
                    if [[ "$VERBOSE" == "true" ]]; then
                        echo "     📄 Error Response: $(echo "$UPDATE_RESPONSE" | jq .)" >&2
                    fi
                fi
            fi
        elif [[ "$SHOULD_PROXY" == "true" ]]; then
            # Need to enable proxy for this record
            if [[ "$RECORD_PROXIED" == "true" && "$FORCE" != "true" ]]; then
                echo "     ✅ Already proxied - no update needed" >&2
                ALREADY_PROXIED_COUNT=$((ALREADY_PROXIED_COUNT + 1))
            else
                if [[ "$RECORD_PROXIED" == "true" && "$FORCE" == "true" ]]; then
                    echo "     🔄 Already proxied but forcing update" >&2
                else
                    echo "     🔄 Needs to be proxied" >&2
                fi
            
                if [[ "$DRY_RUN" == "true" ]]; then
                    echo "     🔍 DRY RUN: Would update this record to proxied=true" >&2
                    cat <<EOF >&2
         curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \\
              -H "Content-Type: application/json" \\
              -H "Authorization: Bearer \$CF_TOKEN" \\
              --data '{"type":"$RECORD_TYPE","name":"$RECORD_NAME","content":"$RECORD_CONTENT","ttl":$RECORD_TTL,"proxied":true}'
EOF
                    UPDATED_COUNT=$((UPDATED_COUNT + 1))
                else
                    local UPDATE_RESPONSE
                    echo "     📡 Updating record to enable proxy..." >&2
                    UPDATE_RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
                        -H "Content-Type: application/json" \
                        -H "Authorization: Bearer $CF_TOKEN" \
                        --data "{\"type\":\"$RECORD_TYPE\",\"name\":\"$RECORD_NAME\",\"content\":\"$RECORD_CONTENT\",\"ttl\":$RECORD_TTL,\"proxied\":true}")

                    if [[ "$VERBOSE" == "true" ]]; then
                        echo "     📡 Update API Response: $(echo "$UPDATE_RESPONSE" | jq -c .)" >&2
                    fi

                    # Check if the update was successful
                    if [[ $(echo "$UPDATE_RESPONSE" | jq -r '.success') == "true" ]]; then
                        echo "     ✅ Successfully enabled proxy for this record" >&2
                        UPDATED_COUNT=$((UPDATED_COUNT + 1))
                    else
                        echo "     ❌ Failed to update this record" >&2
                        if [[ "$VERBOSE" == "true" ]]; then
                            echo "     📄 Error Response: $(echo "$UPDATE_RESPONSE" | jq .)" >&2
                        fi
                    fi
                fi
            fi
        else
            # This shouldn't happen with current logic, but just in case
            echo "     ⏭️  Skipping - no rule defined for this record type" >&2
            SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        fi
        echo >&2
    done
    
    # Return counts: total_count updated_count already_proxied_count skipped_count
    echo "$RECORD_COUNT $UPDATED_COUNT $ALREADY_PROXIED_COUNT $SKIPPED_COUNT"
    return 0
}

# Main function
function main() {
    URL=""
    VERBOSE=false
    DRY_RUN=false
    FORCE=false
    
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
            --dry-run)
                DRY_RUN=true
                ;;
            --force)
                FORCE=true
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
    
    # Check for excluded domains
    if [[ "$URL" == "ciwebgroup.com" ]]; then
        echo "  ⚠️  Domain '$URL' is excluded from proxy management." >&2
        echo "  💡 This domain is protected and will not be modified." >&2
        exit 0
    fi
    
    echo "✔ All checks passed."
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "🔍 DRY RUN MODE: No changes will be made"
    fi
    if [[ "$FORCE" == "true" ]]; then
        echo "💪 FORCE MODE: All records will be updated regardless of current proxy status"
    fi
    echo

    # Step 1: Get Zone ID
    echo "▶ Step 1: Fetching Zone ID for domain: $URL"
    ZONE_RESPONSE=$(curl -s --request GET \
        --url "https://api.cloudflare.com/client/v4/zones?name=$URL" \
        --header "Content-Type: application/json" \
        --header "Authorization: Bearer ${CF_TOKEN}")

    if [[ "$VERBOSE" == "true" ]]; then
        echo "  📡 Zone API Response: $(echo "$ZONE_RESPONSE" | jq -c .)" >&2
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

    # Step 2: Process A Records
    echo "▶ Step 2: Processing A Records..."
    A_RESULTS=$(process_dns_records "$ZONE_ID" "$URL" "A" "$DRY_RUN" "$VERBOSE" "$FORCE")
    if [[ "$VERBOSE" == "true" ]]; then
        echo "  🐛 A_RESULTS: '$A_RESULTS'" >&2
    fi
    A_RECORD_COUNT=$(echo "$A_RESULTS" | cut -d' ' -f1)
    A_UPDATED_COUNT=$(echo "$A_RESULTS" | cut -d' ' -f2)
    A_ALREADY_PROXIED_COUNT=$(echo "$A_RESULTS" | cut -d' ' -f3)
    A_SKIPPED_COUNT=$(echo "$A_RESULTS" | cut -d' ' -f4)
    echo

    # Step 3: Process CNAME Records
    echo "▶ Step 3: Processing CNAME Records..."
    CNAME_RESULTS=$(process_dns_records "$ZONE_ID" "$URL" "CNAME" "$DRY_RUN" "$VERBOSE" "$FORCE")
    if [[ "$VERBOSE" == "true" ]]; then
        echo "  🐛 CNAME_RESULTS: '$CNAME_RESULTS'" >&2
    fi
    CNAME_RECORD_COUNT=$(echo "$CNAME_RESULTS" | cut -d' ' -f1)
    CNAME_UPDATED_COUNT=$(echo "$CNAME_RESULTS" | cut -d' ' -f2)
    CNAME_ALREADY_PROXIED_COUNT=$(echo "$CNAME_RESULTS" | cut -d' ' -f3)
    CNAME_SKIPPED_COUNT=$(echo "$CNAME_RESULTS" | cut -d' ' -f4)
    echo

    # Calculate totals
    TOTAL_RECORDS=$((A_RECORD_COUNT + CNAME_RECORD_COUNT))
    TOTAL_UPDATED=$((A_UPDATED_COUNT + CNAME_UPDATED_COUNT))
    TOTAL_ALREADY_PROXIED=$((A_ALREADY_PROXIED_COUNT + CNAME_ALREADY_PROXIED_COUNT))
    TOTAL_SKIPPED=$((A_SKIPPED_COUNT + CNAME_SKIPPED_COUNT))

    # Check if any records were found
    if [[ $TOTAL_RECORDS -eq 0 ]]; then
        echo "⚠️  Warning: No A or CNAME records found for '$URL'"
        echo "💡 Cannot enable proxy - no suitable DNS records exist"
        exit 1
    fi

    # Final summary
    echo "--- Summary ---"
    echo "Domain: $URL"
    echo "Zone ID: $ZONE_ID"
    echo ""
    echo "A Records:"
    echo "  Total: $A_RECORD_COUNT"
    echo "  Already Proxied: $A_ALREADY_PROXIED_COUNT"
    echo "  Skipped (Rule-based): $A_SKIPPED_COUNT"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  Would Update: $A_UPDATED_COUNT"
    else
        echo "  Successfully Updated: $A_UPDATED_COUNT"
    fi
    echo ""
    echo "CNAME Records:"
    echo "  Total: $CNAME_RECORD_COUNT"
    echo "  Already Proxied: $CNAME_ALREADY_PROXIED_COUNT"
    echo "  Skipped (Rule-based): $CNAME_SKIPPED_COUNT"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  Would Update: $CNAME_UPDATED_COUNT"
    else
        echo "  Successfully Updated: $CNAME_UPDATED_COUNT"
    fi
    echo ""
    echo "Overall Totals:"
    echo "  Total Records: $TOTAL_RECORDS"
    echo "  Already Proxied: $TOTAL_ALREADY_PROXIED"
    echo "  Skipped (Rule-based): $TOTAL_SKIPPED"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  Would Update: $TOTAL_UPDATED"
        echo ""
        echo "🔍 This was a dry run - no actual changes were made"
        echo "💡 Run without --dry-run to apply these changes"
    else
        echo "  Successfully Updated: $TOTAL_UPDATED"
        if [[ $TOTAL_UPDATED -gt 0 ]]; then
            echo ""
            echo "✅ Proxy has been enabled for $TOTAL_UPDATED record(s)"
            echo "💡 Changes may take a few minutes to propagate globally"
        fi
        if [[ $TOTAL_SKIPPED -gt 0 ]]; then
            echo "ℹ️  Skipped $TOTAL_SKIPPED record(s) based on proxying rules"
        fi
    fi
}

# Run the main function with all script arguments
main "$@"