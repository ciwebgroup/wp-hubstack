# Tier Configuration Files

This directory contains tier-specific configuration files for WordPress deployments.

## Structure

```
config/
├── mpm_prefork.conf.tier1      # Apache config for Tier 1 (high-traffic)
├── mpm_prefork.conf.tier2      # Apache config for Tier 2 (medium-traffic)
├── mpm_prefork.conf.tier3      # Apache config for Tier 3 (low-traffic)
├── php-fpm-pool.conf.tier1     # PHP-FPM config for Tier 1
├── php-fpm-pool.conf.tier2     # PHP-FPM config for Tier 2
├── php-fpm-pool.conf.tier3     # PHP-FPM config for Tier 3
├── php-limits.ini.tier1        # PHP limits for Tier 1
├── php-limits.ini.tier2        # PHP limits for Tier 2
└── php-limits.ini.tier3        # PHP limits for Tier 3
```

## Tier Specifications

### Tier 1 (High-Traffic)
- **Capacity:** 2-3 sites per 16GB server
- **Apache Workers:** 15 max
- **PHP-FPM Children:** 15 max
- **Memory Limit:** 512M
- **Target:** Sites with >10,000 visitors/day

### Tier 2 (Medium-Traffic)
- **Capacity:** 5-7 sites per 16GB server
- **Apache Workers:** 10 max
- **PHP-FPM Children:** 10 max
- **Memory Limit:** 384M
- **Target:** Sites with 1,000-10,000 visitors/day

### Tier 3 (Low-Traffic)
- **Capacity:** 10-20 sites per 16GB server
- **Apache Workers:** 5 max
- **PHP-FPM Children:** 5 max
- **Memory Limit:** 256M
- **Target:** Sites with <1,000 visitors/day

## Configuration Path

Set via environment variable:
```bash
CONFIG_DIR=/app/config
```

Or in `.env`:
```
CONFIG_DIR=./config
```

## Customization

To customize tier configurations:

1. Edit the appropriate `.tier*` files in this directory
2. Rebuild Docker image if running in container
3. Redeploy to affected sites

## Deployment

The deployer service automatically selects the correct tier files based on the `--tier` flag:

```bash
# Deploy Tier 2 configs
docker-compose run --rm site-optimizer deploy execute --tier 2 --no-dry-run
```
