# MetaSync Plugin CPU Exhaustion Issue - Remediation Guide

## Executive Summary

**Issue**: MetaSync SEO plugin is causing CPU exhaustion (100%+ CPU usage) on multiple WordPress websites, resulting in frozen shells, unresponsive sites, and container instability.

**Root Cause**: The plugin's background processing systems (Action Scheduler queue processing, OTTO API calls, and log file processing) are creating resource-intensive busy loops that exhaust available CPU cycles.

**Impact**: Affecting multiple production websites, causing service degradation and potential downtime.

**Status**: Ongoing issue requiring immediate remediation and long-term prevention measures.

---

## Problem Description

### Symptoms Observed

1. **High CPU Usage**: Container CPU usage spikes to 148%+ (exceeding allocated 1.5 CPU cores)
2. **Frozen Shell**: Interactive shell becomes unresponsive due to CPU starvation
3. **Parent Process in wait4**: Processes waiting for child processes that never complete
4. **Container Instability**: Frequent restarts and performance degradation
5. **Website Unresponsiveness**: Frontend and backend become slow or inaccessible

### Technical Diagnosis

Based on Gemini AI analysis and log evidence, this is **CPU Starvation caused by Busy Loops**, not:
- ❌ Buffer overruns (would cause immediate crashes)
- ❌ Classic memory leaks (would cause swapping, not high CPU)
- ✅ **Busy loops in background processing** (matches symptoms)

---

## Root Cause Analysis

### Primary Culprit: MetaSync Plugin

The MetaSync plugin (Search Atlas SEO) has three main components causing CPU exhaustion:

#### 1. Action Scheduler Queue Processing
- **Issue**: Large queues of pending actions (observed: 531,419+ bytes of log processing)
- **Problem**: No effective limit on concurrent queue runners
- **Evidence**: Log entries show "Resuming from position: 531419" and "Resuming from position: 1553602"
- **Impact**: Multiple PHP processes spawn to process queue, each consuming CPU

#### 2. OTTO API Feature
- **Issue**: Excessive HTTP requests to external API (10 calls/minute limit, but processing thousands of URLs)
- **Problem**: Processing bot/scanner traffic URLs (404s for malicious paths like `/alfa.php`, `/wp-blog.php`)
- **Evidence**: Log shows thousands of "API returned non-200" and "Rate limited" entries
- **Impact**: Each API call spawns a PHP process, creating CPU-intensive loops

#### 3. Log File Processing
- **Issue**: Processing large debug.log files (1.5MB+ observed)
- **Problem**: Batch processing resumes from large file positions, creating long-running processes
- **Evidence**: "Resuming from position: 1553602" indicates processing multi-megabyte files
- **Impact**: File I/O and processing consume CPU cycles

### Contributing Factors

1. **No Process Limits**: Apache/mod_php has no visible worker limits, allowing unlimited PHP processes
2. **Large Action Queues**: Action Scheduler tables can accumulate thousands of pending actions
3. **OTTO Processing Bot Traffic**: Plugin processes malicious scanner URLs, wasting resources
4. **Insufficient Safeguards**: Existing batch size limits (1000 lines, 30s execution) are insufficient under load

---

## Evidence Gathering

### Immediate Diagnostic Queries

Run these SQL queries to confirm MetaSync is the culprit:

```sql
-- 1. Check Action Scheduler queue size
SELECT COUNT(*) as pending_actions 
FROM wp_actionscheduler_actions 
WHERE status = 'pending';

-- 2. Check for failed/stuck actions
SELECT status, COUNT(*) as count 
FROM wp_actionscheduler_actions 
WHERE hook LIKE '%metasync%' 
GROUP BY status;

-- 3. Check for stuck claims (should be 0)
SELECT COUNT(*) as stuck_claims
FROM wp_actionscheduler_claims 
WHERE claim_date_gmt < DATE_SUB(NOW(), INTERVAL 5 MINUTE);

-- 4. Check OTTO cache entries (indicates API call volume)
SELECT COUNT(*) as otto_cache_entries
FROM wp_options 
WHERE option_name LIKE '_transient_otto_api_%';
```

### Log Analysis

Check these log files for evidence:

1. **MetaSync Plugin Log**: `/wp-content/metasync_data/plugin_errors.log`
   - Look for: "Resuming from position", "Rate limited", "Execution time limit reached"

2. **WordPress Debug Log**: `/wp-content/debug.log`
   - Search for: `MetaSync:`, `action_scheduler`, `metasync_process_seo_job`

3. **Container Log**: `/var/www/log/wordpress-website.log`
   - Check for: Container restart patterns, initialization loops

### Process Monitoring

During high CPU incidents:

```bash
# Check PHP processes
ps aux | grep php | grep -E "metasync|action_scheduler"

# Count Apache workers
ps aux | grep apache2 | wc -l

# Identify high CPU processes
ps aux | grep php | awk '{if ($3 > 50) print}'
```

---

## Immediate Remediation Steps

### Step 1: Emergency Circuit Breaker (Apply Immediately)

Add to `wp-config.php` to temporarily disable MetaSync features:

```php
// Emergency: Disable MetaSync background processing
define('METASYNC_DISABLE_OTTO', true);
define('METASYNC_DISABLE_LOG_SYNC', true);

// Pause Action Scheduler processing
add_filter('action_scheduler_run_queue', '__return_false', 999);
```

**Note**: This will disable MetaSync features but prevent CPU exhaustion. Re-enable after implementing permanent fixes.

### Step 2: Clean Up Action Scheduler Queue

Run these SQL queries to clear stuck actions:

```sql
-- Delete completed actions older than 30 days
DELETE FROM wp_actionscheduler_actions 
WHERE status = 'complete' 
AND scheduled_date_gmt < DATE_SUB(NOW(), INTERVAL 30 DAY);

-- Delete failed actions older than 7 days
DELETE FROM wp_actionscheduler_actions 
WHERE status = 'failed' 
AND scheduled_date_gmt < DATE_SUB(NOW(), INTERVAL 7 DAY);

-- Cancel stuck in-progress actions (older than 1 hour)
UPDATE wp_actionscheduler_actions 
SET status = 'failed' 
WHERE status = 'in-progress' 
AND scheduled_date_gmt < DATE_SUB(NOW(), INTERVAL 1 HOUR);
```

### Step 3: Limit Action Scheduler Processing

Create a Must-Use plugin at `/wp-content/mu-plugins/metasync-limits.php`:

```php
<?php
/**
 * Plugin Name: MetaSync Resource Limits
 * Description: Prevents MetaSync from exhausting CPU resources
 * Version: 1.0
 */

// Limit Action Scheduler batch size
add_filter('action_scheduler_queue_runner_batch_size', function($batch_size) {
    return 10; // Reduce from default 25-50
}, 10, 1);

// Limit concurrent queue runners (CRITICAL)
add_filter('action_scheduler_maximum_concurrent_batches', function($max) {
    return 1; // Only allow 1 concurrent batch
}, 10, 1);

// Reduce Action Scheduler execution time
add_filter('action_scheduler_queue_runner_time_limit', function($time_limit) {
    return 20; // Reduce from default 30 seconds
}, 10, 1);

// Limit MetaSync log processing batch size
add_filter('metasync_log_batch_size', function($batch_size) {
    return 500; // Reduce from 1000
}, 10, 1);

// Limit MetaSync execution time
add_filter('metasync_log_max_execution_time', function($time) {
    return 20; // Reduce from 30 seconds
}, 10, 1);

// Reduce OTTO API rate limit
add_filter('metasync_otto_max_api_calls_per_minute', function() {
    return 5; // Reduce from 10
}, 999);

// Prevent OTTO from processing non-existent URLs (404s)
add_filter('metasync_otto_should_process_url', function($should_process, $url) {
    // Skip processing if URL returns 404
    $response = wp_remote_head($url, array('timeout' => 2));
    if (is_wp_error($response) || wp_remote_retrieve_response_code($response) === 404) {
        return false;
    }
    return $should_process;
}, 10, 2);
```

### Step 4: Configure Apache/PHP Limits

If using Apache with mod_php, add to Apache configuration or `.htaccess`:

```apache
<IfModule mpm_prefork_module>
    StartServers 3
    MinSpareServers 2
    MaxSpareServers 5
    MaxRequestWorkers 10
    MaxConnectionsPerChild 500
</IfModule>
```

Update `php.ini`:

```ini
max_execution_time = 300  # Reduce from 600
max_input_time = 300
memory_limit = 512M  # Reduce from 1G
```

### Step 5: Disable OTTO for Bot Traffic

Add to `wp-config.php` or mu-plugin:

```php
// Prevent MetaSync OTTO from processing scanner/bot URLs
add_filter('metasync_otto_should_process_url', function($should_process, $url) {
    // Block common scanner/malicious paths
    $blocked_patterns = [
        '/alfa\.php',
        '/wp-blog\.php',
        '/wp-update\.php',
        '/cgi-bin/',
        '/\.php$/',  // Block direct PHP file access
    ];
    
    foreach ($blocked_patterns as $pattern) {
        if (preg_match($pattern, $url)) {
            return false;
        }
    }
    
    return $should_process;
}, 999, 2);
```

---

## Long-Term Prevention Measures

### 1. Database Maintenance Cron Job

Add to `crons/nightly.sh`:

```bash
#!/bin/bash

# Clean up Action Scheduler queue
wp db query "DELETE FROM wp_actionscheduler_actions WHERE status = 'complete' AND scheduled_date_gmt < DATE_SUB(NOW(), INTERVAL 30 DAY);" --allow-root

# Alert if queue is too large
PENDING_COUNT=$(wp action-scheduler list --status=pending --format=count --allow-root)
if [ "$PENDING_COUNT" -gt 1000 ]; then
    echo "WARNING: Action Scheduler queue has $PENDING_COUNT pending actions"
    # Add notification logic here
fi
```

### 2. Monitoring Dashboard

Create a monitoring script to track queue health:

```php
<?php
// Add to wp-config.php or create as admin page
function metasync_queue_health_check() {
    global $wpdb;
    
    $pending = $wpdb->get_var("SELECT COUNT(*) FROM {$wpdb->prefix}actionscheduler_actions WHERE status = 'pending'");
    $failed = $wpdb->get_var("SELECT COUNT(*) FROM {$wpdb->prefix}actionscheduler_actions WHERE status = 'failed'");
    $stuck = $wpdb->get_var("SELECT COUNT(*) FROM {$wpdb->prefix}actionscheduler_claims WHERE claim_date_gmt < DATE_SUB(NOW(), INTERVAL 5 MINUTE)");
    
    if ($pending > 1000 || $failed > 100 || $stuck > 0) {
        error_log("MetaSync Queue Health Alert: Pending=$pending, Failed=$failed, Stuck=$stuck");
        // Send alert notification
    }
}
add_action('wp_loaded', 'metasync_queue_health_check');
```

### 3. Container Resource Limits

Update `docker-compose.yml` to add stricter limits:

```yaml
services:
    wp_stoneheatair:
        # ... existing config ...
        deploy:
            resources:
                limits:
                    cpus: '1.5'
                    memory: 1G
                reservations:
                    cpus: '0.5'
                    memory: 512M
        # Add CPU throttling
        ulimits:
            nproc: 20  # Limit number of processes
```

### 4. Switch to PHP-FPM (Recommended)

Replace mod_php with PHP-FPM for better process control:

```ini
# php-fpm pool configuration
[www]
pm = dynamic
pm.max_children = 10
pm.start_servers = 3
pm.min_spare_servers = 2
pm.max_spare_servers = 5
pm.max_requests = 500
pm.process_idle_timeout = 10s
```

---

## Monitoring and Alerting

### Key Metrics to Monitor

1. **Action Scheduler Queue Size**: Should stay under 500 pending actions
2. **Failed Actions Count**: Should stay under 50
3. **Stuck Claims**: Should always be 0
4. **OTTO API Call Rate**: Should not exceed 5 calls/minute
5. **Container CPU Usage**: Should stay under 80% of allocated CPU
6. **PHP Process Count**: Should stay under 15 concurrent processes

### Alert Thresholds

Set up alerts for:
- ⚠️ **Warning**: Queue > 500 pending, CPU > 80%, Process count > 10
- 🚨 **Critical**: Queue > 1000 pending, CPU > 100%, Process count > 15, Stuck claims > 0

### Log Monitoring

Regularly check:
- MetaSync plugin log size (should not exceed 10MB)
- WordPress debug log for MetaSync errors
- Container logs for restart patterns

---

## Emergency Response Procedure

### When CPU Spikes Occur

1. **Immediate (30 seconds)**:
   ```bash
   # Check process count
   ps aux | grep php | wc -l
   
   # Check queue size
   wp action-scheduler list --status=pending --format=count
   ```

2. **Emergency Stop (1 minute)**:
   - Add circuit breaker to `wp-config.php` (see Step 1)
   - Restart container: `docker-compose restart wp_stoneheatair`

3. **Investigation (5 minutes)**:
   - Check MetaSync logs for errors
   - Check database for stuck actions
   - Review recent plugin updates

4. **Recovery (10 minutes)**:
   - Clean up Action Scheduler queue
   - Verify limits are in place
   - Monitor for 15 minutes before declaring resolved

---

## Testing and Validation

### After Implementing Fixes

1. **Load Test**: Monitor CPU usage during peak traffic
2. **Queue Test**: Verify Action Scheduler processes actions without CPU spikes
3. **OTTO Test**: Confirm API calls are rate-limited and don't process 404s
4. **Stress Test**: Simulate high traffic and verify limits hold

### Validation Queries

```sql
-- Should return < 500
SELECT COUNT(*) FROM wp_actionscheduler_actions WHERE status = 'pending';

-- Should return 0
SELECT COUNT(*) FROM wp_actionscheduler_claims 
WHERE claim_date_gmt < DATE_SUB(NOW(), INTERVAL 5 MINUTE);

-- Should return reasonable number (< 1000)
SELECT COUNT(*) FROM wp_options 
WHERE option_name LIKE '_transient_otto_api_%';
```

---

## Plugin Configuration Recommendations

### MetaSync Settings to Review

1. **OTTO Feature**: Consider disabling if not essential
   - Location: MetaSync → OTTO Settings
   - Action: Disable or reduce processing frequency

2. **Log Sync**: Reduce frequency if enabled
   - Location: MetaSync → Log Sync Settings
   - Action: Increase interval or disable

3. **Action Scheduler**: Monitor queue regularly
   - Location: WordPress → Tools → Scheduled Actions
   - Action: Review and clean up regularly

### Alternative Solutions

If issues persist:
1. **Contact MetaSync Support**: Report the CPU exhaustion issue
2. **Consider Alternative Plugin**: Evaluate other SEO plugins if MetaSync cannot be stabilized
3. **Disable Problematic Features**: Disable OTTO and log sync if not critical

---

## Implementation Checklist

### Immediate Actions (Do First)
- [ ] Add emergency circuit breaker to `wp-config.php`
- [ ] Clean up Action Scheduler queue (SQL queries)
- [ ] Create mu-plugin with resource limits
- [ ] Restart container and monitor

### Short-Term Actions (Within 24 Hours)
- [ ] Configure Apache/PHP limits
- [ ] Add OTTO bot traffic filter
- [ ] Set up monitoring queries
- [ ] Document incident details

### Long-Term Actions (Within 1 Week)
- [ ] Implement database maintenance cron
- [ ] Set up alerting system
- [ ] Review and optimize container resources
- [ ] Consider PHP-FPM migration
- [ ] Create runbook for team

### Ongoing Maintenance
- [ ] Weekly: Review Action Scheduler queue size
- [ ] Weekly: Check MetaSync log file size
- [ ] Monthly: Clean up old Action Scheduler actions
- [ ] Monthly: Review CPU usage trends
- [ ] Quarterly: Review and update limits

---

## Additional Resources

### Documentation
- [Action Scheduler Documentation](https://actionscheduler.org/)
- [WordPress Must-Use Plugins](https://wordpress.org/documentation/article/must-use-plugins/)
- [Docker Resource Limits](https://docs.docker.com/config/containers/resource_constraints/)

### Support Contacts
- MetaSync Plugin Support: [Check plugin admin for support link]
- WordPress Support: [Your WordPress support channel]
- Infrastructure Team: [Your infrastructure team contact]

---

## Revision History

| Date | Version | Changes | Author |
|------|---------|---------|--------|
| 2025-12-19 | 1.0 | Initial documentation | System Analysis |

---

## Notes

- This issue affects **multiple websites** using the MetaSync plugin
- The problem is **recurring** and requires permanent fixes, not just temporary workarounds
- All fixes should be tested in staging before applying to production
- Monitor closely for 48 hours after implementing fixes
- Document any additional issues or workarounds discovered

---

**Last Updated**: 2025-12-19  
**Status**: Active Issue - Remediation In Progress  
**Priority**: High - Production Impact

