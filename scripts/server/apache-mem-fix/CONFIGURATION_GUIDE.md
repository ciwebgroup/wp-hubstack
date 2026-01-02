# Docker Container Resource Configuration Guide

## Server Specifications
- **CPU:** 8 cores @ 2GHz
- **RAM:** 16GB total
- **Architecture:** Isolated Docker containers per WordPress site

## Configuration Philosophy

Since each WordPress site runs in its own Docker container, we optimize for:
1. **Per-container isolation** - Each site has dedicated resources
2. **Memory efficiency** - Prevent leaks with process recycling
3. **CPU utilization** - Match worker counts to available cores
4. **Performance** - Opcache and realpath caching enabled

---

## Applied Configurations

### 1. Apache MPM Prefork (`mpm_prefork.conf`)

```apache
<IfModule mpm_prefork_module>
    StartServers             3
    MinSpareServers          3
    MaxSpareServers          8
    MaxRequestWorkers        25
    MaxConnectionsPerChild   500
</IfModule>
```

**Key Changes:**
- ✅ `MaxConnectionsPerChild: 500` (was 0) - **Prevents memory leaks**
- ✅ `MaxRequestWorkers: 25` (was 20) - Better utilization of 16GB RAM
- ✅ `MaxSpareServers: 8` (was 5) - Matches CPU core count

**Per-Container Resource Usage:**
- Light load: 3-5 Apache processes × ~50MB = 150-250MB
- Medium load: 10-15 processes × ~50MB = 500-750MB
- Peak load: 25 processes × ~50MB = 1.25GB

---

### 2. PHP-FPM Pool (`php-fpm-pool.conf`)

```ini
[www]
pm = dynamic
pm.max_children = 25
pm.start_servers = 5
pm.min_spare_servers = 3
pm.max_spare_servers = 8
pm.max_requests = 500
pm.process_idle_timeout = 30s

; Monitoring endpoints
pm.status_path = /status
ping.path = /ping
ping.response = pong
```

**Key Changes:**
- ✅ `pm.max_children: 25` (was 10) - **2.5x increase** for better concurrency
- ✅ `pm.process_idle_timeout: 30s` (was 10s) - **Reduces process thrashing**
- ✅ `pm.max_spare_servers: 8` (was 5) - Matches CPU cores
- ✅ Added monitoring endpoints for health checks

**Per-Container Resource Usage:**
- Light load: 5 processes × 256MB = 1.3GB
- Medium load: 15 processes × 256MB = 3.8GB
- Peak load: 25 processes × 256MB = 6.4GB

---

### 3. PHP Limits (`php-limits.ini`)

```ini
; Execution limits
max_execution_time = 300
max_input_time = 300
memory_limit = 512M

; Upload limits
post_max_size = 128M
upload_max_filesize = 128M

; Input limits (for large forms - WooCommerce, page builders)
max_input_vars = 5000
max_input_nesting_level = 64

; Opcache settings (performance boost)
opcache.enable = 1
opcache.memory_consumption = 256
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 10000
opcache.revalidate_freq = 60
opcache.validate_timestamps = 1
opcache.fast_shutdown = 1
opcache.enable_cli = 0

; Realpath cache (performance)
realpath_cache_size = 4096K
realpath_cache_ttl = 600
```

**Key Additions:**
- ✅ Upload limits (128MB) - Large media files
- ✅ `max_input_vars: 5000` - WooCommerce/Elementor support
- ✅ **Opcache enabled** - 256MB shared cache = **significant performance boost**
- ✅ Realpath cache - Reduces filesystem stat() calls

---

## Resource Calculations

### Per-Container Maximum Usage

```
Apache:     25 workers × 50MB   = 1.25GB
PHP-FPM:    25 workers × 256MB  = 6.40GB
MySQL:                          = 1.50GB (typical)
Opcache:    (shared)            = 0.26GB
System:                         = 0.50GB
                                --------
Total per container:            = 9.91GB (peak)
```

### Server Capacity

With 16GB RAM total:
- **1 site:** 9.9GB used, 6.1GB free ✅ Excellent
- **2 sites:** 19.8GB needed ⚠️ Would need swap or reduced limits
- **Recommended:** 1-2 sites per 16GB server with these limits

### Optimization for Multiple Sites

If running 2+ sites per server, reduce per-container limits:

```ini
# Adjusted for 2 sites per server
pm.max_children = 15              # Instead of 25
MaxRequestWorkers = 15            # Instead of 25
```

This gives each container ~6GB peak usage, allowing 2 sites comfortably.

---

## Performance Benefits

### 1. Opcache Impact
- **Before:** Every PHP file read from disk on each request
- **After:** Compiled PHP cached in memory
- **Expected improvement:** 30-50% faster response times

### 2. Process Recycling
- **Before:** Memory leaks accumulate indefinitely (MaxConnectionsPerChild = 0)
- **After:** Processes recycled every 500 requests
- **Benefit:** Stable memory usage over time

### 3. Reduced Process Thrashing
- **Before:** Idle processes killed after 10s
- **After:** Idle processes kept for 30s
- **Benefit:** Faster response to traffic bursts

---

## Monitoring Commands

### Check PHP-FPM Status
```bash
# Inside container
curl http://localhost/status

# From host
docker exec wp_container_name curl http://localhost/status
```

### Check Process Counts
```bash
# PHP-FPM processes
docker exec wp_container_name ps aux | grep php-fpm | wc -l

# Apache processes
docker exec wp_container_name ps aux | grep apache2 | wc -l
```

### Check Memory Usage
```bash
# Container memory usage
docker stats wp_container_name --no-stream

# Detailed process memory
docker exec wp_container_name ps aux --sort=-%mem | head -20
```

---

## Deployment

### Apply to All Sites
```bash
cd /var/www/ciwebgroup/wp-hubstack/scripts/server/apache-mem-fix

# Preview changes
./apply_fix.sh --dry-run --php-fpm --php-limits

# Apply to all sites
./apply_fix.sh --php-fpm --php-limits --restart

# Apply to specific sites only
./apply_fix.sh --php-fpm --php-limits --restart --include "example.com,mysite.com"

# Apply to all except staging
./apply_fix.sh --php-fpm --php-limits --restart --exclude "staging,dev"
```

### Verify Configuration
```bash
# Check Apache config
docker exec wp_container_name apache2ctl -M | grep mpm_prefork

# Check PHP-FPM config
docker exec wp_container_name php-fpm -tt

# Check PHP settings
docker exec wp_container_name php -i | grep -E "memory_limit|max_execution_time|opcache"
```

---

## Troubleshooting

### Issue: 502 Bad Gateway Errors

**Cause:** All PHP-FPM workers busy

**Solution:**
```bash
# Increase max_children
pm.max_children = 30  # or higher
```

### Issue: High Memory Usage

**Cause:** Too many concurrent processes

**Solution:**
```bash
# Reduce limits
pm.max_children = 20
MaxRequestWorkers = 20
```

### Issue: Slow Response Times

**Cause:** Opcache not working

**Check:**
```bash
docker exec wp_container_name php -i | grep opcache.enable
# Should show: opcache.enable => On => On
```

---

## Next Steps

1. **Deploy configurations** using `apply_fix.sh`
2. **Monitor for 24-48 hours** using the monitoring commands above
3. **Adjust if needed** based on actual usage patterns
4. **Document per-site** any custom adjustments needed

## Notes

- These configurations are optimized for **isolated Docker containers**
- Each container is independent - one site's load won't affect others
- Resource limits prevent any single container from consuming all server resources
- Opcache provides significant performance improvements with minimal memory cost
