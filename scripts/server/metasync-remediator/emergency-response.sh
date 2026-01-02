#!/bin/bash
set -eauo pipefail

# MetaSync Emergency Response Script
# Run this when CPU spikes occur

# Configuration
CONTAINER_NAME="${1:-wp_container}"
SITE_DIR="${2:-/var/opt/sites/example.com}"

echo "=========================================="
echo "MetaSync Emergency Response"
echo "Container: $CONTAINER_NAME"
echo "=========================================="
echo ""

# Step 1: Check process count
echo "[1/5] Checking PHP process count..."
PHP_COUNT=$(docker exec "$CONTAINER_NAME" ps aux | grep php | grep -v grep | wc -l || echo "0")
echo "PHP processes: $PHP_COUNT"
echo ""

# Step 2: Check queue size
echo "[2/5] Checking Action Scheduler queue..."
PENDING_COUNT=$(docker exec "$CONTAINER_NAME" wp action-scheduler list --status=pending --format=count --allow-root 2>/dev/null || echo "0")
echo "Pending actions: $PENDING_COUNT"
echo ""

# Step 3: Check for high CPU processes
echo "[3/5] Checking for high CPU processes..."
docker exec "$CONTAINER_NAME" ps aux | grep php | awk '{if ($3 > 50) print $0}' || true
echo ""

# Step 4: Emergency stop if needed
if [ "$PHP_COUNT" -gt 15 ] || [ "$PENDING_COUNT" -gt 1000 ]; then
    echo "[4/5] CRITICAL: Thresholds exceeded!"
    echo "  - PHP processes: $PHP_COUNT (threshold: 15)"
    echo "  - Pending actions: $PENDING_COUNT (threshold: 1000)"
    echo ""
    read -p "Apply emergency circuit breaker and restart? (y/n) " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Applying circuit breaker..."
        # Copy circuit breaker to mu-plugins
        docker cp metasync-circuit-breaker.php "$CONTAINER_NAME:/var/www/html/wp-content/mu-plugins/"
        
        echo "Restarting container..."
        (cd "$SITE_DIR" && docker compose restart)
        
        echo "✓ Emergency measures applied"
    fi
else
    echo "[4/5] Status: Within normal thresholds"
fi
echo ""

# Step 5: Show recent MetaSync errors
echo "[5/5] Checking recent MetaSync errors..."
docker exec "$CONTAINER_NAME" tail -n 20 /var/www/html/wp-content/metasync_data/plugin_errors.log 2>/dev/null || echo "No MetaSync log found"
echo ""

echo "=========================================="
echo "Emergency response complete"
echo "=========================================="
