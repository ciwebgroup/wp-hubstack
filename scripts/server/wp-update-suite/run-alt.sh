#!/bin/bash

MAIN_PATH="/var/opt/scripts/wp-update-suite/main.py"

# Get current path

if [ ! -f "$MAIN_PATH" ]; then
    echo "Error: main.py not found at $MAIN_PATH"
    exit 1
fi

# Run the script with Python 3
#python3 "$MAIN_PATH" "$@"
python3 "$MAIN_PATH" --all-containers --non-interactive --no-backup --check-update-db-schema --update-plugins all --update-themes all --mirror-wp-assets --restart-docker >> /root/logs/wp-update-suite.log 2>&1
