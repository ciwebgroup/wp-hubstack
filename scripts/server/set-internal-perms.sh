#!/bin/bash

set -euo pipefail

# Script to find domain-like subdirectories and set their permissions
# Usage: ./set_domain_permissions.sh [--parent-dir /path/to/directory] --user-group user:group

# --- Configuration Variables ---
PARENT_DIR="$(pwd)"           # Default to current directory
USER_GROUP=""                 # User:group to set permissions for
DRY_RUN="no"                  # Set to 'yes' to simulate actions without making changes
VERBOSE_MODE="no"             # Set to 'yes' to enable detailed logging
CHOWN_ONLY="no"               # Set to 'yes' to only change ownership, not permissions
CHMOD_VALUE=""                # Custom chmod value to apply (e.g., 755, 644, etc.)
CHMOD_TYPE=""                 # Type to apply chmod to: 'f' (files), 'd' (directories), or empty (both)

# --- Script Functions ---

# Function to display usage information
usage() {
    echo "Usage: $0 [OPTIONS] --user-group <user:group>"
    echo "Finds domain-like subdirectories and sets their permissions recursively."
    echo ""
    echo "Options:"
    echo "  --parent-dir <directory>     Specify parent directory to scan (default: current directory)"
    echo "  --user-group <user:group>    User and group to set ownership to (required)"
    echo "  --chown-only                 Only change ownership, preserve existing permissions"
    echo "  --chmod <permissions>        Set custom permissions (e.g., 755, 644, 775)"
    echo "  --chmod-type <f|d>           Apply chmod only to files (f) or directories (d)"
    echo "  --verbose                    Enable verbose logging and detailed output"
    echo "  --dry-run                    Simulate the execution without making any changes"
    echo "  -h, --help                   Display this help message"
    echo ""
    echo "Examples:"
    echo "  # Set permissions for domain directories in current directory:"
    echo "  sudo $0 --user-group www-data:www-data"
    echo ""
    echo "  # Set permissions for domain directories in specific directory:"
    echo "  sudo $0 --parent-dir /var/www --user-group nginx:nginx"
    echo ""
    echo "  # Only change ownership, preserve existing permissions:"
    echo "  sudo $0 --parent-dir /var/www --user-group nginx:nginx --chown-only"
    echo ""
    echo "  # Set custom permissions for all files and directories:"
    echo "  sudo $0 --parent-dir /var/www --user-group nginx:nginx --chmod 775"
    echo ""
    echo "  # Set permissions only for files (644):"
    echo "  sudo $0 --parent-dir /var/www --user-group nginx:nginx --chmod 644 --chmod-type f"
    echo ""
    echo "  # Set permissions only for directories (755):"
    echo "  sudo $0 --parent-dir /var/www --user-group nginx:nginx --chmod 755 --chmod-type d"
    echo ""
    echo "  # Dry run to see what would be changed:"
    echo "  sudo $0 --parent-dir /var/www --user-group nginx:nginx --dry-run --verbose"
    echo ""
    echo "Domain Detection:"
    echo "  The script identifies directories that look like domain names with TLDs."
    echo "  Examples: example.com, mysite.org, business.tech, company.co.uk"
    echo "  Supports traditional TLDs (.com, .org, .net), country codes (.uk, .de, .jp),"
    echo "  and modern generic TLDs (.app, .dev, .io, .tech, etc.)"
    echo ""
    echo "Permission Modes:"
    echo "  Default: Sets ownership and permissions (755 for dirs, 644 for files)"
    echo "  --chown-only: Only changes ownership, preserves existing permissions"
    echo "  --chmod: Sets ownership and custom permissions (applies same value to all files/dirs)"
    echo "  --chmod-type: When used with --chmod, applies permissions only to files (f) or directories (d)"
    exit 1
}

# Function for logging messages
log() {
    local prefix=""
    if [ "${DRY_RUN}" == "yes" ]; then
        prefix="[DRY RUN] "
    fi
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ${prefix}$1"
}

# Function for verbose logging
verbose_log() {
    if [ "${VERBOSE_MODE}" == "yes" ]; then
        local prefix="[VERBOSE] "
        if [ "${DRY_RUN}" == "yes" ]; then
            prefix="[DRY RUN VERBOSE] "
        fi
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] ${prefix}$1"
    fi
}

# Function for error handling and exiting
error_exit() {
    log "ERROR: $1" >&2
    if [ "${DRY_RUN}" == "no" ]; then
        exit 1
    else
        log "Dry run indicates this would have been a fatal error."
    fi
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to execute a command or log it during dry run
execute_or_log() {
    local cmd_description="$1"
    shift
    local cmd_to_execute=("$@")

    log "${cmd_description}: ${cmd_to_execute[*]}"
    if [ "${DRY_RUN}" == "no" ]; then
        "${cmd_to_execute[@]}"
        return $?
    fi
    return 0
}

# Function to check if a directory name looks like a domain name with TLD
is_domain_like() {
    local dirname="$1"
    
    # Convert to lowercase for case-insensitive matching
    local lowercase_dirname=$(echo "$dirname" | tr '[:upper:]' '[:lower:]')
    
    # Comprehensive list of TLDs (traditional, country code, and modern generic TLDs)
    local tlds=(
        # Traditional TLDs
        "com" "org" "net" "edu" "gov" "mil" "int" "info" "biz" "name" "pro" "aero" "coop" "museum"
        
        # Country code TLDs (major ones)
        "us" "uk" "ca" "au" "de" "fr" "it" "jp" "cn" "ru" "br" "mx" "in" "es" "nl" "ch" "se" "no" "dk" "fi"
        "be" "at" "pl" "ie" "pt" "gr" "cz" "hu" "sk" "si" "bg" "ro" "hr" "rs" "ba" "mk" "al" "me" "md"
        "ua" "by" "lt" "lv" "ee" "is" "mt" "cy" "lu" "li" "ad" "mc" "sm" "va" "gi" "im" "je" "gg"
        "za" "eg" "ma" "ng" "ke" "gh" "tz" "ug" "rw" "mw" "zm" "zw" "bw" "na" "sz" "ls" "mg" "mu"
        "kr" "tw" "hk" "sg" "my" "th" "ph" "id" "vn" "bd" "pk" "lk" "np" "mm" "kh" "la" "bn" "mv"
        "ar" "cl" "pe" "co" "ve" "uy" "py" "bo" "ec" "gf" "sr" "gy" "fk" "cr" "gt" "hn" "ni" "pa"
        "cu" "do" "ht" "jm" "tt" "bb" "gd" "lc" "vc" "ag" "dm" "kn" "ms" "ai" "vg" "vi" "pr" "bz"
        "nz" "fj" "pg" "sb" "vu" "nc" "pf" "ws" "to" "tv" "ki" "nr" "pw" "fm" "mh" "mp" "gu" "as"
        
        # Modern generic TLDs
        "app" "dev" "io" "ai" "tech" "blog" "shop" "store" "online" "site" "website" "web" "digital"
        "cloud" "host" "domains" "email" "click" "link" "download" "zip" "mov" "new" "art" "design"
        "studio" "agency" "company" "business" "services" "solutions" "consulting" "management" "group"
        "team" "work" "jobs" "career" "professional" "expert" "guru" "ninja" "rocks" "cool" "fun"
        "game" "games" "play" "sport" "fitness" "health" "medical" "dental" "clinic" "hospital"
        "law" "legal" "attorney" "lawyer" "accountant" "tax" "finance" "bank" "money" "insurance"
        "loan" "credit" "investment" "trading" "forex" "crypto" "bitcoin" "blockchain" "nft"
        "education" "academy" "school" "college" "university" "training" "course" "learn" "study"
        "news" "media" "tv" "radio" "music" "video" "photo" "gallery" "movie" "film" "theater"
        "book" "library" "author" "writer" "publisher" "magazine" "journal" "review" "blog"
        "food" "restaurant" "cafe" "bar" "pub" "wine" "beer" "pizza" "kitchen" "recipe" "cooking"
        "travel" "hotel" "flights" "vacation" "holiday" "tour" "cruise" "adventure" "camping"
        "fashion" "clothing" "shoes" "jewelry" "beauty" "cosmetics" "salon" "spa" "wellness"
        "auto" "car" "cars" "truck" "motorcycle" "bike" "parts" "repair" "garage" "dealer"
        "house" "home" "real" "estate" "property" "apartment" "rent" "buy" "sell" "mortgage"
        "garden" "flowers" "plants" "landscaping" "construction" "tools" "equipment" "supplies"
        "pet" "pets" "dog" "cat" "animal" "vet" "veterinary" "grooming" "breeding" "training"
        "baby" "kids" "children" "toys" "games" "family" "mom" "dad" "parenting" "pregnancy"
        "senior" "retirement" "pension" "insurance" "life" "death" "funeral" "memorial"
        "charity" "foundation" "nonprofit" "volunteer" "community" "social" "environment"
        "green" "eco" "solar" "energy" "power" "electric" "gas" "oil" "mining" "metals"
        "science" "research" "lab" "laboratory" "chemistry" "physics" "biology" "medicine"
        "technology" "software" "hardware" "computer" "internet" "wireless" "mobile" "phone"
        "security" "safety" "protection" "guard" "alarm" "camera" "surveillance" "monitoring"
        "cleaning" "maintenance" "repair" "service" "support" "help" "customer" "client"
        "marketing" "advertising" "promotion" "sales" "commerce" "trade" "export" "import"
        "logistics" "shipping" "delivery" "transport" "freight" "cargo" "warehouse" "storage"
        "manufacturing" "factory" "production" "industrial" "machinery" "equipment" "tools"
        "agriculture" "farming" "livestock" "crops" "seeds" "fertilizer" "organic" "natural"
        "fishing" "marine" "ocean" "sea" "water" "river" "lake" "beach" "island" "coast"
        "mountain" "ski" "snow" "winter" "summer" "spring" "fall" "weather" "climate"
        "city" "town" "village" "county" "state" "country" "region" "local" "global" "international"
        "xxx" "adult" "sex" "dating" "singles" "romance" "love" "wedding" "marriage" "divorce"
    )
    
    # Check if dirname ends with any of the TLDs
    for tld in "${tlds[@]}"; do
        # Check if dirname ends with .tld (with dot)
        if [[ "$lowercase_dirname" =~ \.$tld$ ]]; then
            verbose_log "Directory '$dirname' matches TLD pattern (.$tld)"
            return 0
        fi
        # Also check if dirname ends with just the tld (without dot)
        if [[ "$lowercase_dirname" =~ ^.*[^a-zA-Z0-9]$tld$ ]] || [[ "$lowercase_dirname" == *"$tld" ]]; then
            # Make sure it's not just a substring match - require word boundary
            if [[ "$lowercase_dirname" =~ (^|[^a-zA-Z0-9])$tld$ ]]; then
                verbose_log "Directory '$dirname' matches TLD pattern ($tld)"
                return 0
            fi
        fi
    done
    
    # Additional check for domain-like patterns (at least one dot and valid characters)
    if [[ "$lowercase_dirname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]]; then
        verbose_log "Directory '$dirname' matches generic domain pattern"
        return 0
    fi
    
    verbose_log "Directory '$dirname' does not match any domain pattern"
    return 1
}

# Function to find domain-like subdirectories
find_domain_directories() {
    local parent_dir="$1"
    local domain_dirs=()
    
    log "Scanning for domain-like directories in: ${parent_dir}"
    
    # Validate parent directory
    if [ ! -d "${parent_dir}" ]; then
        error_exit "Parent directory does not exist: ${parent_dir}"
    fi
    
    # Convert to absolute path
    local abs_parent_dir
    if command_exists realpath; then
        abs_parent_dir=$(realpath "${parent_dir}")
    else
        abs_parent_dir=$(cd "${parent_dir}" && pwd)
    fi
    
    verbose_log "Parent directory (absolute): ${abs_parent_dir}"
    
    # Find all subdirectories and check if they match domain patterns
    while IFS= read -r -d '' dir; do
        # Get basename for the directory
        local basename=$(basename "${dir}")
        
        # Skip if directory name is empty or contains problematic characters
        if [[ -z "${basename}" ]] || [[ "${basename}" =~ [[:space:]] ]] || [[ "${basename}" =~ \.\. ]]; then
            verbose_log "Skipping directory with problematic name: ${basename}"
            continue
        fi
        
        # Check if directory name looks like a domain
        if is_domain_like "${basename}"; then
            domain_dirs+=("${dir}")
            verbose_log "Found domain directory: ${basename} -> ${dir}"
        else
            verbose_log "Skipping non-domain directory: ${basename}"
        fi
        
    done < <(find "${abs_parent_dir}" -maxdepth 1 -type d ! -path "${abs_parent_dir}" -print0 2>/dev/null)
    
    # If no directories found with find, try ls approach
    if [ ${#domain_dirs[@]} -eq 0 ]; then
        log "No subdirectories found using find. Trying ls approach..."
        
        for dir in "${abs_parent_dir}"/*/; do
            if [ -d "${dir}" ]; then
                local basename=$(basename "${dir}")
                
                # Skip if directory name contains problematic characters
                if [[ -z "${basename}" ]] || [[ "${basename}" =~ [[:space:]] ]] || [[ "${basename}" =~ \.\. ]]; then
                    verbose_log "Skipping directory with problematic name: ${basename}"
                    continue
                fi
                
                if is_domain_like "${basename}"; then
                    domain_dirs+=("${dir}")
                    verbose_log "Found domain directory: ${basename} -> ${dir}"
                else
                    verbose_log "Skipping non-domain directory: ${basename}"
                fi
            fi
        done
    fi
    
    # Return the array properly by printing each element on a separate line
    printf '%s\n' "${domain_dirs[@]}"
}

# Function to set permissions for a directory and its contents
set_directory_permissions() {
    local directory="$1"
    local user_group="$2"
    
    log "Setting permissions for: ${directory}"
    
    # Validate directory exists
    if [ ! -d "${directory}" ]; then
        log "Warning: Directory does not exist: ${directory}"
        return 1
    fi
    
    # Get current ownership for comparison
    local current_owner=$(stat -c '%U:%G' "${directory}" 2>/dev/null || echo "unknown:unknown")
    verbose_log "Current ownership: ${current_owner}"
    
    # Set ownership recursively
    execute_or_log "Setting ownership of ${directory} to ${user_group}" sudo chown -R "${user_group}" "${directory}" || {
        log "Warning: Failed to set ownership of ${directory}. Check manually."
        return 1
    }
    
    # Set permissions only if not in chown-only mode
    if [ "${CHOWN_ONLY}" == "no" ]; then
        if [ -n "${CHMOD_VALUE}" ]; then
            if [ "${CHMOD_TYPE}" == "f" ]; then
                verbose_log "Setting custom permissions for ${directory} (${CHMOD_VALUE} for files only)"
                execute_or_log "Setting permissions for files in ${directory}" sudo find "${directory}" -type f -exec chmod "${CHMOD_VALUE}" {} \; || {
                    log "Warning: Failed to set permissions for files in ${directory}. Check manually."
                    return 1
                }
            elif [ "${CHMOD_TYPE}" == "d" ]; then
                verbose_log "Setting custom permissions for ${directory} (${CHMOD_VALUE} for directories only)"
                execute_or_log "Setting permissions for directories in ${directory}" sudo find "${directory}" -type d -exec chmod "${CHMOD_VALUE}" {} \; || {
                    log "Warning: Failed to set permissions for directories in ${directory}. Check manually."
                    return 1
                }
            else
                verbose_log "Setting custom permissions for ${directory} (${CHMOD_VALUE} for all files and directories)"
                execute_or_log "Setting permissions for ${directory}" sudo chmod -R "${CHMOD_VALUE}" "${directory}" || {
                    log "Warning: Failed to set permissions for ${directory}. Check manually."
                    return 1
                }
            fi
        else
            verbose_log "Setting permissions for ${directory} (755 for dirs, 644 for files)"
            execute_or_log "Setting permissions for ${directory}" sudo find "${directory}" -type d -exec chmod 755 {} \; -o -type f -exec chmod 644 {} \; || {
                log "Warning: Failed to set permissions for ${directory}. Check manually."
                return 1
            }
        fi
    else
        verbose_log "Skipping permission changes (--chown-only mode enabled)"
    fi
    
    # Verify the change
    local new_owner=$(stat -c '%U:%G' "${directory}" 2>/dev/null || echo "unknown:unknown")
    if [ "${new_owner}" != "${current_owner}" ]; then
        log "✓ Successfully changed ownership from ${current_owner} to ${new_owner}"
    else
        log "✓ Ownership already set to ${new_owner}"
    fi
    
    # Show permission status
    if [ "${CHOWN_ONLY}" == "yes" ]; then
        log "✓ Preserved existing permissions (--chown-only mode)"
    elif [ -n "${CHMOD_VALUE}" ]; then
        if [ "${CHMOD_TYPE}" == "f" ]; then
            log "✓ Set custom permissions (${CHMOD_VALUE} for files only)"
        elif [ "${CHMOD_TYPE}" == "d" ]; then
            log "✓ Set custom permissions (${CHMOD_VALUE} for directories only)"
        else
            log "✓ Set custom permissions (${CHMOD_VALUE} for all files and directories)"
        fi
    else
        log "✓ Set standard permissions (755 for directories, 644 for files)"
    fi
    
    return 0
}

# Function to parse command-line arguments
parse_arguments() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --parent-dir)
                PARENT_DIR="$2"
                shift 2
                ;;
            --user-group)
                USER_GROUP="$2"
                shift 2
                ;;
            --chown-only)
                CHOWN_ONLY="yes"
                shift
                ;;
            --chmod)
                CHMOD_VALUE="$2"
                if [[ -z "$CHMOD_VALUE" ]]; then
                    error_exit "Permission value is required with --chmod. Please provide a value (e.g., 755, 644)."
                fi
                # Validate permission format (3 or 4 digit octal)
                if [[ ! "$CHMOD_VALUE" =~ ^[0-7]{3,4}$ ]]; then
                    error_exit "Invalid permission format: '${CHMOD_VALUE}'. Please use octal format (e.g., 755, 644, 0755)."
                fi
                shift 2
                ;;
            --chmod-type)
                CHMOD_TYPE="$2"
                if [[ -z "$CHMOD_TYPE" ]]; then
                    error_exit "Type value is required with --chmod-type. Please provide 'f' for files or 'd' for directories."
                fi
                # Validate type format (must be 'f' or 'd')
                if [[ ! "$CHMOD_TYPE" =~ ^[fd]$ ]]; then
                    error_exit "Invalid chmod type: '${CHMOD_TYPE}'. Please use 'f' for files or 'd' for directories."
                fi
                shift 2
                ;;
            --verbose)
                VERBOSE_MODE="yes"
                shift
                ;;
            --dry-run)
                DRY_RUN="yes"
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                error_exit "Unknown option: $1"
                ;;
        esac
    done
}

# Function to validate user:group format
validate_user_group() {
    local user_group="$1"
    
    # Check if user:group format is provided
    if [[ ! "$user_group" =~ ^[a-zA-Z0-9_.-]+:[a-zA-Z0-9_.-]+$ ]]; then
        error_exit "Invalid user:group format: '${user_group}'. Expected format: 'user:group'"
    fi
    
    # Extract user and group
    local user="${user_group%%:*}"
    local group="${user_group##*:}"
    
    # Check if user exists
    if ! id "${user}" &>/dev/null; then
        error_exit "User '${user}' does not exist on the system"
    fi
    
    # Check if group exists
    if ! getent group "${group}" &>/dev/null; then
        error_exit "Group '${group}' does not exist on the system"
    fi
    
    verbose_log "Validated user:group - User: ${user}, Group: ${group}"
}

# Main function
main() {
    # Parse command-line arguments
    parse_arguments "$@"
    
    # Check for required user:group parameter
    if [ -z "${USER_GROUP}" ]; then
        error_exit "User:group parameter is required. Use --user-group <user:group>"
    fi
    
    # Check for conflicting flags
    if [ "${CHOWN_ONLY}" == "yes" ] && [ -n "${CHMOD_VALUE}" ]; then
        error_exit "Cannot use --chown-only and --chmod together. Choose one: preserve permissions or set custom permissions."
    fi
    
    # Check that --chmod-type is only used with --chmod
    if [ -n "${CHMOD_TYPE}" ] && [ -z "${CHMOD_VALUE}" ]; then
        error_exit "--chmod-type can only be used with --chmod. Please specify a permission value with --chmod."
    fi
    
    # Validate user:group format
    validate_user_group "${USER_GROUP}"
    
    # Check for root privileges (required for chown)
    if [[ $EUID -ne 0 ]]; then
        error_exit "This script must be run as root. Please use sudo."
    fi
    
    log "Starting domain directory permission setup"
    log "Parent directory: ${PARENT_DIR}"
    log "User:group: ${USER_GROUP}"
    log "Chown-only mode: ${CHOWN_ONLY}"
    if [ -n "${CHMOD_VALUE}" ]; then
        log "Custom chmod value: ${CHMOD_VALUE}"
        if [ -n "${CHMOD_TYPE}" ]; then
            if [ "${CHMOD_TYPE}" == "f" ]; then
                log "Chmod target: Files only"
            elif [ "${CHMOD_TYPE}" == "d" ]; then
                log "Chmod target: Directories only"
            fi
        else
            log "Chmod target: All files and directories"
        fi
    fi
    log "Dry run enabled: ${DRY_RUN}"
    log "Verbose mode: ${VERBOSE_MODE}"
    echo ""
    
    # Find domain-like directories
    local domain_directories
    mapfile -t domain_directories < <(find_domain_directories "${PARENT_DIR}")
    
    if [ ${#domain_directories[@]} -eq 0 ]; then
        log "No domain-like directories found in: ${PARENT_DIR}"
        log "The script looks for directories with names like: example.com, mysite.org, business.tech"
        return 0
    fi
    
    log "Found ${#domain_directories[@]} domain-like directory(ies):"
    for dir in "${domain_directories[@]}"; do
        log "  - $(basename "${dir}")"
    done
    echo ""
    
    # Set permissions for each domain directory
    local success_count=0
    local failed_count=0
    
    for directory in "${domain_directories[@]}"; do
        if set_directory_permissions "${directory}" "${USER_GROUP}"; then
            success_count=$((success_count + 1))
        else
            failed_count=$((failed_count + 1))
        fi
        echo ""
    done
    
    # Summary
    log "=== SETUP SUMMARY ==="
    log "Total domain directories found: ${#domain_directories[@]}"
    log "Successfully processed: ${success_count}"
    log "Failed to process: ${failed_count}"
    log "User:group applied: ${USER_GROUP}"
    if [ "${CHOWN_ONLY}" == "yes" ]; then
        log "Mode: Ownership only (permissions preserved)"
    elif [ -n "${CHMOD_VALUE}" ]; then
        if [ "${CHMOD_TYPE}" == "f" ]; then
            log "Mode: Ownership and custom permissions (${CHMOD_VALUE} for files only)"
        elif [ "${CHMOD_TYPE}" == "d" ]; then
            log "Mode: Ownership and custom permissions (${CHMOD_VALUE} for directories only)"
        else
            log "Mode: Ownership and custom permissions (${CHMOD_VALUE} for all)"
        fi
    else
        log "Mode: Ownership and permissions (755/644)"
    fi
    echo ""
    
    if [ ${failed_count} -eq 0 ]; then
        log "✓ All domain directories have been processed successfully!"
    else
        log "⚠ ${failed_count} directory(ies) had issues. Check the logs above for details."
        if [ "${DRY_RUN}" == "no" ]; then
            exit 1
        fi
    fi
}

# Execute the main function
main "$@"

set +euo pipefail
