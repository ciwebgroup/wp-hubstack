# Domain Expiry Notifications - Quick Start Guide

## What This Does

Automatically checks domain expiry dates for all WordPress installations running in Docker containers and alerts when domains are expiring within 30 days (or custom threshold).

## Setup

1. **Navigate to the directory:**

   ```bash
   cd /var/www/ciwebgroup/wp-hubstack/scripts/server/domain-expiry-notifications
   ```

2. **Build the Docker image:**

   ```bash
   docker-compose build
   ```

3. **Test the setup:**
   ```bash
   ./test-setup.sh
   ```

## Quick Usage

```bash
# Check all domains (30-day threshold)
./run.sh

# Check with 60-day threshold
./run.sh --days 60

# Check specific container
./run.sh --container wp_example_com

# Test without WHOIS queries
./run.sh --dry-run -v

# Save results to file (auto-detects format from extension)
./run.sh --output results.json
./run.sh --output results.csv
./run.sh --output report.txt

# Output as JSON to stdout (legacy)
./run.sh --json
```

## How It Works

1. **Discovery**: Finds all Docker containers with names starting with `wp_`
2. **Extract Domain**: Gets domain from container's `WP_HOME` environment variable
3. **WHOIS Lookup**: Queries domain expiry using python-whois or system whois command
4. **Alert**: Reports domains expiring within threshold period

## Requirements

- WordPress containers must be named with `wp_` prefix (e.g., `wp_example_com`)
- Containers must have `WP_HOME` environment variable set (e.g., `WP_HOME=https://example.com`)
- Docker socket access (`/var/run/docker.sock`)

## Example Output

```
================================================================================
DOMAIN EXPIRY CHECK SUMMARY
================================================================================

📊 Total domains checked: 5
🟡 Expiring within 30 days: 2
🔴 Expired: 0
❌ Errors: 0

================================================================================
🟡 DOMAINS EXPIRING WITHIN 30 DAYS:
================================================================================
  example.com (container: wp_example_com)
    Days remaining: 15
    Expiry date: 2026-02-05
```

## Automation

Add to crontab for daily checks:

```bash
# Daily at 7 AM
0 7 * * * cd /var/www/ciwebgroup/wp-hubstack/scripts/server/domain-expiry-notifications && ./run.sh >> /var/log/domain-expiry.log 2>&1
```

See [cron-examples.txt](cron-examples.txt) for more cron job examples.

## Exit Codes

- `0` - All domains OK
- `1` - Domains expiring soon or expired (requires action)

## Files

- `main.py` - Main Python script
- `Dockerfile` - Docker image definition
- `docker-compose.yml` - Docker Compose configuration
- `requirements.txt` - Python dependencies
- `run.sh` - Convenience script to run the checker
- `test-setup.sh` - Verify setup and test functionality
- `cron-examples.txt` - Sample cron job configurations
- `README.md` - Full documentation

## Troubleshooting

**No domains found?**

- Ensure containers are named with `wp_` prefix
- Verify `WP_HOME` environment variable is set

**WHOIS failing?**

- Some registrars have rate limits
- Try with `--dry-run` for testing
- Check logs with `-v` flag

For full documentation, see [README.md](README.md)
