#!/bin/bash

# Uptime Kuma Docker Container Monitor Sync Script
# This script sets up a Python virtual environment and runs the Uptime Kuma monitor sync

set -euo pipefail

# Change to the script directory
cd "$(dirname "$0")"

# Load environment variables if .env exists
if [ -f ".env" ]; then
    set -a
    source .env
    set +a
    echo "Loaded environment variables from .env"
else
    echo "Warning: .env file not found. Please create one based on uptime-kuma-env-sample.txt"
    echo "You can copy the sample: cp uptime-kuma-env-sample.txt .env"
fi

# Check if Python virtual environment exists
if [ ! -d "venv-uptime-kuma" ]; then
    echo "Creating Python virtual environment..."
    python3 -m venv venv-uptime-kuma
fi

# Activate virtual environment
echo "Activating virtual environment..."
source venv-uptime-kuma/bin/activate

# Install/update requirements
echo "Installing/updating Python dependencies..."
pip install -r requirements-uptime-kuma.txt

# Run the Uptime Kuma monitoring script
echo "Starting Uptime Kuma monitor sync..."
echo "Arguments passed: $*"

# Run the script with all passed arguments
python3 main.py "$@"

echo "Uptime Kuma monitor sync completed." 
