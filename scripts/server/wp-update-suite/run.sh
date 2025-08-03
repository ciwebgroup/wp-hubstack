#!/bin/bash

MAIN_PATH="/var/opt/scripts/wp-update-suite/main.py"

if [ ! -f "$MAIN_PATH" ]; then
	echo "Error: main.py not found at $MAIN_PATH"
	exit 1
fi

# Run the script with Python 3
python3 "$MAIN_PATH" "$@"
