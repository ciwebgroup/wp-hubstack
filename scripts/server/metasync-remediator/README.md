# MetaSync Remediator Scripts

This directory contains scripts and plugins extracted from the MetaSync CPU Issue Remediation Guide.

## Directory Contents

### Must-Use Plugins (Copy to wp-content/mu-plugins/)

1. **metasync-limits.php** - Resource limits for MetaSync
   - Reduces batch sizes and concurrent runners
   - Limits execution times
   - Filters 404 URLs from OTTO processing

2. **metasync-bot-filter.php** - Bot traffic filter
   - Blocks common scanner/malicious paths
   - Prevents wasting resources on bot traffic

3. **metasync-circuit-breaker.php** - Emergency circuit breaker
   - Completely disables MetaSync background processing
   - Use only during critical incidents

4. **metasync-queue-monitor.php** - Queue health monitor
   - Tracks Action Scheduler queue size
   - Logs alerts when thresholds exceeded

### SQL Scripts

1. **diagnostic-queries.sql** - Diagnostic queries
   - Check queue sizes and stuck actions
   - Identify MetaSync-related issues

2. **cleanup-action-scheduler.sql** - Queue cleanup
   - Remove old completed/failed actions
   - Cancel stuck in-progress actions

3. **validation-queries.sql** - Validation queries
   - Verify fixes are working
   - Check queue health after remediation

### Shell Scripts

1. **nightly-maintenance.sh** - Nightly maintenance cron
   - Cleans up old Action Scheduler actions
   - Alerts on large queue sizes
   - Usage: `./nightly-maintenance.sh wp_container_name`

2. **emergency-response.sh** - Emergency response
   - Diagnose CPU spikes
   - Apply circuit breaker if needed
   - Usage: `./emergency-response.sh wp_container_name /path/to/site`

3. **monitor-cpu.sh** - Continuous CPU monitoring
   - Track CPU usage in real-time
   - Alert on threshold breaches
   - Usage: `./monitor-cpu.sh wp_container_name [interval] [threshold]`

### Configuration Files

1. **mpm_prefork.conf** - Apache MPM Prefork config
   - Conservative worker limits
   - Copy to Apache mods-available

2. **php-fpm-pool.conf** - PHP-FPM pool config
   - Dynamic process management
   - Conservative limits

3. **php-limits.ini** - PHP configuration
   - Execution time and memory limits

4. **docker-compose-limits.yml** - Docker resource limits
   - Example CPU and memory constraints
   - Process limits via ulimits

## Quick Start

### Emergency Response (CPU Spike)

```bash
# 1. Run emergency response script
./emergency-response.sh wp_container_name /var/opt/sites/example.com

# 2. If needed, manually apply circuit breaker
docker cp metasync-circuit-breaker.php wp_container_name:/var/www/html/wp-content/mu-plugins/
docker compose restart
```

### Preventive Installation

```bash
# 1. Copy resource limits to mu-plugins
docker cp metasync-limits.php wp_container_name:/var/www/html/wp-content/mu-plugins/
docker cp metasync-bot-filter.php wp_container_name:/var/www/html/wp-content/mu-plugins/
docker cp metasync-queue-monitor.php wp_container_name:/var/www/html/wp-content/mu-plugins/

# 2. Clean up Action Scheduler queue
docker exec wp_container_name wp db query "$(cat cleanup-action-scheduler.sql)" --allow-root

# 3. Set up nightly maintenance cron
chmod +x nightly-maintenance.sh
# Add to crontab: 0 2 * * * /path/to/nightly-maintenance.sh wp_container_name
```

### Monitoring

```bash
# Start continuous monitoring
chmod +x monitor-cpu.sh
./monitor-cpu.sh wp_container_name 10 80
```

## Files Reference

| File | Type | Purpose | Location |
|------|------|---------|----------|
| metasync-limits.php | PHP | Resource limits | mu-plugins/ |
| metasync-bot-filter.php | PHP | Bot filtering | mu-plugins/ |
| metasync-circuit-breaker.php | PHP | Emergency stop | mu-plugins/ |
| metasync-queue-monitor.php | PHP | Queue monitoring | mu-plugins/ |
| diagnostic-queries.sql | SQL | Diagnostics | Run via wp db query |
| cleanup-action-scheduler.sql | SQL | Queue cleanup | Run via wp db query |
| validation-queries.sql | SQL | Validation | Run via wp db query |
| nightly-maintenance.sh | Bash | Cron job | Server crontab |
| emergency-response.sh | Bash | Incident response | Run manually |
| monitor-cpu.sh | Bash | Monitoring | Run manually |
| mpm_prefork.conf | Apache | Worker limits | Apache config |
| php-fpm-pool.conf | PHP-FPM | Process limits | PHP-FPM config |
| php-limits.ini | PHP | PHP limits | PHP config |
| docker-compose-limits.yml | YAML | Container limits | docker-compose.yml |

## See Also

- [METASYNC_CPU_ISSUE_REMEDIATION.md](./METASYNC_CPU_ISSUE_REMEDIATION.md) - Full remediation guide
