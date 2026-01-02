#!/bin/bash
set -eauo pipefail

# MetaSync Nightly Maintenance
# Add to crontab: 0 2 * * * /path/to/nightly-maintenance.sh

# Configuration
CONTAINER_NAME="${1:-wp_container}"
ALERT_THRESHOLD=1000

echo "Starting MetaSync maintenance for container: $CONTAINER_NAME"

# Clean up Action Scheduler queue
echo "Cleaning up old Action Scheduler actions..."
docker exec "$CONTAINER_NAME" wp db query "DELETE FROM wp_actionscheduler_actions WHERE status = 'complete' AND scheduled_date_gmt < DATE_SUB(NOW(), INTERVAL 30 DAY);" --allow-root

# Alert if queue is too large
echo "Checking queue size..."
PENDING_COUNT=$(docker exec "$CONTAINER_NAME" wp action-scheduler list --status=pending --format=count --allow-root 2>/dev/null || echo "0")

if [ "$PENDING_COUNT" -gt "$ALERT_THRESHOLD" ]; then
    echo "WARNING: Action Scheduler queue has $PENDING_COUNT pending actions (threshold: $ALERT_THRESHOLD)"
    # Add notification logic here (email, webhook, etc.)
    # Example: curl -X POST https://your-webhook-url -d "Queue size: $PENDING_COUNT"
else
    echo "Queue size OK: $PENDING_COUNT pending actions"
fi

echo "Maintenance complete"
