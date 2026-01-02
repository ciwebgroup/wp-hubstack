#!/bin/bash
set -eauo pipefail

# MetaSync CPU Monitor
# Continuously monitor CPU usage and alert on spikes

# Configuration
CONTAINER_NAME="${1:-wp_container}"
CHECK_INTERVAL="${2:-10}"  # seconds
CPU_THRESHOLD="${3:-80}"   # percentage

echo "Monitoring CPU for container: $CONTAINER_NAME"
echo "Check interval: ${CHECK_INTERVAL}s"
echo "Alert threshold: ${CPU_THRESHOLD}%"
echo "Press Ctrl+C to stop"
echo ""

while true; do
    # Get CPU usage
    CPU_USAGE=$(docker stats "$CONTAINER_NAME" --no-stream --format "{{.CPUPerc}}" | sed 's/%//' || echo "0")
    
    # Get process count
    PHP_COUNT=$(docker exec "$CONTAINER_NAME" ps aux | grep php | grep -v grep | wc -l 2>/dev/null || echo "0")
    
    # Get timestamp
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Check if CPU is above threshold
    if (( $(echo "$CPU_USAGE > $CPU_THRESHOLD" | bc -l) )); then
        echo "[$TIMESTAMP] ⚠️  ALERT: CPU: ${CPU_USAGE}% | PHP Processes: $PHP_COUNT"
        
        # Show top processes
        echo "Top CPU processes:"
        docker exec "$CONTAINER_NAME" ps aux | grep php | awk '{if ($3 > 10) print $0}' | head -5 || true
        echo ""
    else
        echo "[$TIMESTAMP] ✓ OK: CPU: ${CPU_USAGE}% | PHP Processes: $PHP_COUNT"
    fi
    
    sleep "$CHECK_INTERVAL"
done
