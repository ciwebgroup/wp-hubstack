# Tier Classification Guide

## Overview

The tier classification system automatically assigns sites to performance tiers (1, 2, or 3) based on traffic thresholds and validates assignments against server capacity.

## Quick Start

### 1. Auto-Classify All Sites

```bash
# Use default thresholds (Tier 1: 10k+, Tier 2: 1k+)
docker-compose run --rm site-optimizer classify auto

# Custom thresholds
docker-compose run --rm site-optimizer classify auto \
  --tier1-threshold 15000 \
  --tier2-threshold 2000

# Overwrite existing classifications
docker-compose run --rm site-optimizer classify auto --overwrite
```

### 2. Manual Tier Assignment

```bash
# Set specific site to Tier 1
docker-compose run --rm site-optimizer classify set example.com 1

# Set to Tier 2
docker-compose run --rm site-optimizer classify set mysite.com 2

# Set to Tier 3
docker-compose run --rm site-optimizer classify set blog.com 3
```

### 3. Review Classifications

```bash
# Show summary
docker-compose run --rm site-optimizer classify review

# JSON output
docker-compose run --rm site-optimizer classify review --format json
```

Output:
```
Tier Classification Summary

Total Sites: 548
  Tier 1 (High): 15
  Tier 2 (Medium): 120
  Tier 3 (Low): 350
  Unassigned: 63

Classification Progress: 88.5%

⚠ 8 servers have capacity issues
```

### 4. Validate Server Capacity

```bash
# Validate all servers
docker-compose run --rm site-optimizer classify validate

# Validate specific server
docker-compose run --rm site-optimizer classify validate --server server01.example.com
```

Output shows:
- Tier distribution per server
- Estimated RAM usage
- Available RAM
- Utilization percentage
- Capacity status (OK/OVER)

### 5. Get Recommendations

```bash
docker-compose run --rm site-optimizer classify recommend
```

Shows sites where traffic patterns suggest a different tier than currently assigned.

## Classification Logic

### Tier Thresholds

| Tier | Daily Visitors | Default Threshold |
|------|----------------|-------------------|
| 1 (High) | ≥ 10,000 | Configurable |
| 2 (Medium) | 1,000 - 9,999 | Configurable |
| 3 (Low) | < 1,000 | Default |

### Without Traffic Data

Sites without traffic data default to **Tier 3** (most conservative).

## Capacity Validation

The system validates that servers can handle assigned tiers:

### RAM Estimation

- **Tier 1:** ~4.5GB per site
- **Tier 2:** ~2.75GB per site
- **Tier 3:** ~1.25GB per site

### Example Validation

```
Server: server01.example.com
  Tier 1 sites: 2 × 4.5GB = 9GB
  Tier 2 sites: 3 × 2.75GB = 8.25GB
  Tier 3 sites: 5 × 1.25GB = 6.25GB
  Total estimated: 23.5GB
  Available RAM: 11GB (16GB - 5GB system/MySQL)
  Status: ✗ OVER CAPACITY
```

## Workflow Examples

### Example 1: Initial Classification

```bash
# 1. Import sites
docker-compose run --rm site-optimizer inventory import --file sites.csv

# 2. Auto-classify (defaults to Tier 3 without traffic data)
docker-compose run --rm site-optimizer classify auto

# 3. Review results
docker-compose run --rm site-optimizer classify review

# 4. Validate capacity
docker-compose run --rm site-optimizer classify validate
```

### Example 2: Update Classifications

```bash
# 1. Get recommendations based on traffic
docker-compose run --rm site-optimizer classify recommend

# 2. Apply specific changes
docker-compose run --rm site-optimizer classify set bigstore.com 1
docker-compose run --rm site-optimizer classify set mediumsite.com 2

# 3. Re-validate
docker-compose run --rm site-optimizer classify validate
```

### Example 3: Bulk Re-classification

```bash
# Re-classify all sites with new thresholds
docker-compose run --rm site-optimizer classify auto \
  --tier1-threshold 20000 \
  --tier2-threshold 5000 \
  --overwrite

# Check impact
docker-compose run --rm site-optimizer classify review
```

## Integration with Deployment

Once sites are classified, you can deploy tier-specific configurations:

```bash
# Deploy Tier 1 configs to high-traffic sites
cd ../apache-mem-fix
./apply_fix.sh --tier 1 --include "bigstore.com,mainsite.com" --restart

# Deploy Tier 3 configs to low-traffic sites
./apply_fix.sh --tier 3 --exclude "bigstore.com,mainsite.com" --restart
```

## Tips

### Start Conservative

When in doubt, start with lower tiers and upgrade based on actual performance:

```bash
# Default everything to Tier 3
docker-compose run --rm site-optimizer classify auto

# Manually upgrade known high-traffic sites
docker-compose run --rm site-optimizer classify set bigstore.com 1
```

### Monitor After Classification

After applying tier configurations:

1. Monitor server resource usage
2. Check for 502/504 errors
3. Review site performance
4. Adjust tiers as needed

### Handle Capacity Issues

If validation shows over-capacity servers:

```bash
# 1. Identify problem servers
docker-compose run --rm site-optimizer classify validate

# 2. Options:
#    a) Downgrade some sites to lower tiers
#    b) Migrate sites to other servers
#    c) Add more server capacity

# 3. Re-validate after changes
docker-compose run --rm site-optimizer classify validate
```

## Configuration

### Environment Variables

```bash
# .env file
TIER1_MIN_VISITORS=10000
TIER2_MIN_VISITORS=1000
```

### Override at Runtime

```bash
docker-compose run --rm site-optimizer classify auto \
  --tier1-threshold 15000 \
  --tier2-threshold 2000
```

## Next Steps

After classification:

1. **Phase 4:** Plan migrations for over-capacity servers
2. **Phase 5:** Deploy tier-specific configurations
3. **Phase 6:** Monitor and adjust based on actual usage
