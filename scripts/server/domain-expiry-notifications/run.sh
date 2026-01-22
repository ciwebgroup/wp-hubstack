#!/bin/bash
# Convenience script to run domain expiry checker

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$SCRIPT_DIR" || exit 1

# Build if image doesn't exist
if ! docker images | grep -q "ciweb/domain-expiry-checker"; then
    echo "Building domain-expiry-checker image..."
    docker compose build
fi

# Run the checker
docker compose run --rm domain-expiry-checker "$@"
