#!/bin/bash

MAIN_PATH=$(readlink -f './main.py')

if [ ! -f "$MAIN_PATH" ]; then
	echo "Error: main.py not found at $MAIN_PATH"
	exit 1
fi

# Run the script with Python 3
python3 "$MAIN_PATH" "$@"