#!/bin/bash
# Quick test script to verify the domain expiry checker setup

echo "==================================================================="
echo "Testing Domain Expiry Checker Setup"
echo "==================================================================="
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

echo "1. Checking if Docker is available..."
if ! command -v docker &> /dev/null; then
    echo "   ❌ Docker is not installed or not in PATH"
    exit 1
fi
echo "   ✅ Docker is available"
echo ""

echo "2. Checking if Docker Compose is available..."
if ! docker compose version &> /dev/null; then
    echo "   ❌ Docker Compose is not installed or not in PATH"
    exit 1
fi
echo "   ✅ Docker Compose is available"
echo ""

echo "3. Building Docker image..."
if docker compose build; then
    echo "   ✅ Image built successfully"
else
    echo "   ❌ Failed to build image"
    exit 1
fi
echo ""

echo "4. Checking for WordPress containers..."
WP_CONTAINERS=$(docker ps --format '{{.Names}}' | grep '^wp_' || true)
if [ -z "$WP_CONTAINERS" ]; then
    echo "   ⚠️  No WordPress containers found (this is okay for testing)"
    echo "   Note: Container names should start with 'wp_'"
else
    echo "   ✅ Found WordPress containers:"
    echo "$WP_CONTAINERS" | sed 's/^/      - /'
fi
echo ""

echo "5. Running dry-run test..."
if docker compose run --rm domain-expiry-checker python3 main.py --dry-run -v; then
    echo "   ✅ Dry-run completed successfully"
else
    echo "   ⚠️  Dry-run exited with error (may be expected if no containers found)"
fi
echo ""

echo "==================================================================="
echo "Setup verification complete!"
echo ""
echo "To run the checker:"
echo "  ./run.sh                    # Check all domains (30-day threshold)"
echo "  ./run.sh --days 60          # Check with 60-day threshold"
echo "  ./run.sh --dry-run -v       # Test without WHOIS queries"
echo "  ./run.sh --json             # Output as JSON"
echo "==================================================================="
