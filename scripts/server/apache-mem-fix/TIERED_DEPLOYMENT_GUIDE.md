# Tiered Configuration System - Deployment Guide

## Overview

This tiered system allows you to deploy different resource limits based on site traffic levels, optimizing resource usage on high-density servers (16+ sites per 16GB server).

## Tier Specifications

### **Tier 1: High-Traffic Sites**
**Capacity:** 2-3 sites per 16GB server

| Setting | Value |
|---------|-------|
| MaxRequestWorkers | 15 |
| pm.max_children | 15 |
| memory_limit | 512M |
| upload_max_filesize | 128M |
| opcache.memory_consumption | 256MB |
| **Peak RAM per site** | **~4-5GB** |

**Use for:**
- Primary revenue-generating sites
- High-traffic WooCommerce stores
- Sites with > 10,000 visitors/day
- Mission-critical applications

---

### **Tier 2: Medium-Traffic Sites**
**Capacity:** 5-7 sites per 16GB server

| Setting | Value |
|---------|-------|
| MaxRequestWorkers | 10 |
| pm.max_children | 10 |
| memory_limit | 384M |
| upload_max_filesize | 96M |
| opcache.memory_consumption | 192MB |
| **Peak RAM per site** | **~2.5-3GB** |

**Use for:**
- Standard business websites
| Moderate WooCommerce stores
- Sites with 1,000-10,000 visitors/day
- Corporate sites with regular traffic

---

### **Tier 3: Low-Traffic Sites**
**Capacity:** 10-20 sites per 16GB server

| Setting | Value |
|---------|-------|
| MaxRequestWorkers | 5 |
| pm.max_children | 5 |
| memory_limit | 256M |
| upload_max_filesize | 64M |
| opcache.memory_consumption | 128MB |
| **Peak RAM per site** | **~1-1.5GB** |

**Use for:**
- Blogs and informational sites
- Brochure websites
- Sites with < 1,000 visitors/day
- Development/staging sites

---

## Quick Start

### **1. Classify Your Sites**

Create a site inventory by traffic tier:

```bash
# Tier 1 (High-Traffic)
TIER1_SITES="bigstore.com,mainsite.com,primarysite.com"

# Tier 2 (Medium-Traffic)
TIER2_SITES="business1.com,business2.com,shop3.com"

# Tier 3 (Low-Traffic) - All others
# Use --exclude to skip Tier 1 and 2 sites
```

### **2. Deploy Tier 1 (High-Traffic Sites)**

```bash
cd /var/www/ciwebgroup/wp-hubstack/scripts/server/apache-mem-fix

# Preview changes
./apply_fix.sh --tier 1 --include "bigstore.com,mainsite.com" --dry-run

# Apply changes
./apply_fix.sh --tier 1 --include "bigstore.com,mainsite.com" --restart
```

### **3. Deploy Tier 2 (Medium-Traffic Sites)**

```bash
# Apply to specific sites
./apply_fix.sh --tier 2 --include "business1.com,business2.com" --restart
```

### **4. Deploy Tier 3 (Low-Traffic Sites)**

```bash
# Apply to all remaining sites (exclude Tier 1 & 2)
./apply_fix.sh --tier 3 --exclude "bigstore.com,mainsite.com,business1.com,business2.com" --restart
```

---

## Deployment Examples

### **Example 1: Single Site**
```bash
# Deploy Tier 2 to one specific site
./apply_fix.sh --tier 2 --include "example.com" --restart
```

### **Example 2: Preview Before Applying**
```bash
# Always preview first!
./apply_fix.sh --tier 3 --dry-run --include "testsite.com"
```

### **Example 3: Batch Deployment**
```bash
# Deploy to multiple sites at once
./apply_fix.sh --tier 1 \
  --include "site1.com,site2.com,site3.com" \
  --restart
```

### **Example 4: Exclude Specific Sites**
```bash
# Apply to all except staging/dev
./apply_fix.sh --tier 3 \
  --exclude "staging,dev,test" \
  --restart
```

---

## Resource Planning

### **Server Capacity Calculator**

For a 16GB RAM server:

```
Available RAM: 16GB
System overhead: -2GB
MySQL (shared): -3GB
Available for sites: 11GB
```

**Tier 1 sites:** 11GB / 4.5GB = **2 sites max**  
**Tier 2 sites:** 11GB / 2.75GB = **4 sites max**  
**Tier 3 sites:** 11GB / 1.25GB = **8 sites max**

### **Mixed Tier Example**

```
1 × Tier 1 site = 4.5GB
3 × Tier 2 sites = 8.25GB
4 × Tier 3 sites = 5GB
                  -------
Total: 17.75GB (at peak)

Realistic usage (30% peak): ~12GB ✅ Fits!
```

---

## Configuration Files

The system includes these configuration files:

```
apache-mem-fix/
├── mpm_prefork.conf.tier1       # Tier 1 Apache config
├── mpm_prefork.conf.tier2       # Tier 2 Apache config
├── mpm_prefork.conf.tier3       # Tier 3 Apache config
├── php-fpm-pool.conf.tier1      # Tier 1 PHP-FPM config
├── php-fpm-pool.conf.tier2      # Tier 2 PHP-FPM config
├── php-fpm-pool.conf.tier3      # Tier 3 PHP-FPM config
├── php-limits.ini.tier1         # Tier 1 PHP limits
├── php-limits.ini.tier2         # Tier 2 PHP limits
├── php-limits.ini.tier3         # Tier 3 PHP limits
├── apply_fix.sh             # Deployment script
└── apply_fix.sh                 # Base deployment script
```

---

## Monitoring After Deployment

### **Check Container Memory Usage**

```bash
# All containers
docker stats --no-stream

# Specific container
docker stats wp_example_com --no-stream
```

### **Check PHP-FPM Process Count**

```bash
# Should not exceed pm.max_children for the tier
docker exec wp_example_com ps aux | grep php-fpm | wc -l
```

### **Check for 502 Errors**

```bash
# If seeing 502 errors, site may need higher tier
docker logs wp_example_com --tail 100 | grep -i "502\|bad gateway"
```

---

## Upgrading/Downgrading Tiers

### **Upgrade Site to Higher Tier**

If a site outgrows its current tier:

```bash
# Move from Tier 3 to Tier 2
./apply_fix.sh --tier 2 --include "growing-site.com" --restart
```

### **Downgrade Site to Lower Tier**

If a site has reduced traffic:

```bash
# Move from Tier 1 to Tier 2
./apply_fix.sh --tier 2 --include "quieter-site.com" --restart
```

---

## Troubleshooting

### **Issue: 502 Bad Gateway Errors**

**Symptom:** Site returns 502 errors during traffic spikes

**Cause:** All PHP-FPM workers busy (pm.max_children too low)

**Solution:** Upgrade to higher tier
```bash
./apply_fix.sh --tier 2 --include "problematic-site.com" --restart
```

---

### **Issue: High Memory Usage**

**Symptom:** Server running out of RAM

**Cause:** Too many sites or wrong tier assignments

**Solutions:**
1. Move low-traffic sites to Tier 3
2. Reduce number of sites on server
3. Check for memory leaks in specific sites

```bash
# Find memory-hungry containers
docker stats --no-stream | sort -k4 -h
```

---

### **Issue: Slow Response Times**

**Symptom:** Sites loading slowly

**Possible causes:**
1. Tier too low (not enough workers)
2. OPcache not enabled
3. Database bottleneck

**Check OPcache:**
```bash
docker exec wp_example_com php -r "echo opcache_get_status() ? 'Enabled' : 'Disabled';"
```

---

## Best Practices

1. **Always preview first** with `--dry-run`
2. **Monitor for 24-48 hours** after deployment
3. **Start conservative** (lower tier) and upgrade if needed
4. **Document tier assignments** for each site
5. **Review quarterly** and adjust tiers based on traffic changes
6. **Keep backups** before making changes

---

## Site Classification Worksheet

Use this to plan your deployments:

```
Server: _________________
Total RAM: 16GB
Total Sites: ___

Tier 1 Sites (High-Traffic):
[ ] _________________ (estimated visitors/day: _____)
[ ] _________________ (estimated visitors/day: _____)
Total Tier 1: ___ sites × 4.5GB = ___GB

Tier 2 Sites (Medium-Traffic):
[ ] _________________ (estimated visitors/day: _____)
[ ] _________________ (estimated visitors/day: _____)
[ ] _________________ (estimated visitors/day: _____)
Total Tier 2: ___ sites × 2.75GB = ___GB

Tier 3 Sites (Low-Traffic):
[ ] _________________ (estimated visitors/day: _____)
[ ] _________________ (estimated visitors/day: _____)
[ ] _________________ (estimated visitors/day: _____)
Total Tier 3: ___ sites × 1.25GB = ___GB

Total Peak RAM: ___GB (should be < 14GB)
```

---

## Next Steps

1. ✅ Classify your sites by traffic tier
2. ✅ Test deployment with `--dry-run` first
3. ✅ Deploy Tier 1 sites (highest priority)
4. ✅ Deploy Tier 2 sites
5. ✅ Deploy Tier 3 sites (remaining)
6. ✅ Monitor for 48 hours
7. ✅ Adjust tiers as needed

---

## Support

For issues or questions:
- Check container logs: `docker logs wp_container_name`
- Monitor resources: `docker stats`
- Review configuration: `docker exec wp_container_name php -i | grep -E "memory_limit|max_children"`
