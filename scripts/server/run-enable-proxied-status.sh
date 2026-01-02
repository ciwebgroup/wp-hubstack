#!/bin/bash

# Usage: ./run-enable-proxied-status.sh --dir <directory> [--dry-run] [--record-json-path <path>]

DIR="$HOME/logs/a_records"
RECORD_JSON_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)
            DIR="$2"
            shift 2
            ;;
        --record-json-path)
            RECORD_JSON_PATH="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

process_record_json() {
    local file="$1"
    name=$(jq -r '.result[0].name' "$file")
    /var/opt/scripts/enable-proxied-status.sh --url "$name" --force --verbose >> "$HOME/logs/enable-proxied-status-$name.log" 2>&1
    # IS_PROXIED=$(jq -r '.result[0].proxied' "$file")
    # if [[ "$IS_PROXIED" == "false" ]]; then
	# 	echo "\$name: $name"
    #     if [[ $DRY_RUN -eq 1 ]]; then
    #         echo "[DRY RUN] Would run: /var/opt/scripts/enable-proxied-status.sh --domain <(echo \"$name\")"
    #     else
    #     fi
    # fi
}

if [[ -n "$RECORD_JSON_PATH" ]]; then
    process_record_json "$RECORD_JSON_PATH"
else
	if [[ ! -d "$DIR" ]]; then
		echo "Directory $DIR does not exist."
		exit 1
	fi
	echo "Processing JSON files in directory: $DIR"
    find "$DIR" -type f -iname 'record*json' -print0 | while IFS= read -r -d '' file; do
        process_record_json "$file"
    done
fi