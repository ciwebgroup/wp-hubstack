# Domain Expiry Notifications

A Dockerized Python script that checks domain expiry dates for all WordPress installations and alerts when domains are expiring within a specified threshold (default: 30 days).

## Features

- 🔍 Automatically discovers all WordPress Docker containers (containers starting with `wp_`)
- 📅 Checks domain expiry dates using WHOIS
- ⚠️ Alerts when domains expire within threshold period (default: 30 days)
- 🐍 Uses both `python-whois` library and system `whois` command for maximum compatibility
- 🎯 Can check all domains or a specific container
- 📊 Provides detailed summary reports
- 🔄 Supports JSON output for automation

## How It Works

The script:

1. Discovers WordPress containers by listing all Docker containers with names starting with `wp_`
2. Extracts the domain from each container's `WP_HOME` environment variable
3. Performs WHOIS lookups to determine expiry dates
4. Compares expiry dates against the threshold (default: 30 days)
5. Reports domains that are expired or expiring soon

## Requirements

- Docker
- Docker Compose
- Access to Docker socket (`/var/run/docker.sock`)
- WordPress containers must have `WP_HOME` environment variable set

## Installation

### Build the Docker Image

```bash
cd /var/www/ciwebgroup/wp-hubstack/scripts/server/domain-expiry-notifications
docker-compose build
```

## Usage

### Check All Domains (Default: 30-day threshold)

```bash
docker-compose run --rm domain-expiry-checker
```

### Check with Custom Threshold (e.g., 60 days)

```bash
docker-compose run --rm domain-expiry-checker python3 main.py --days 60
```

### Check Specific Container

```bash
docker-compose run --rm domain-expiry-checker python3 main.py --container wp_example_com
```

### Dry Run (Test Without WHOIS Queries)

```bash
docker-compose run --rm domain-expiry-checker python3 main.py --dry-run
```

### Verbose Output

```bash
docker-compose run --rm domain-expiry-checker python3 main.py -v
```

### Save Results to File

The `--output` flag automatically detects the format from the file extension:

**JSON Format (.json)**

```bash
docker-compose run --rm domain-expiry-checker python3 main.py --output results.json
```

**CSV Format (.csv)**

```bash
docker-compose run --rm domain-expiry-checker python3 main.py --output results.csv
```

**Text Table Format (.txt)**

```bash
docker-compose run --rm domain-expiry-checker python3 main.py --output report.txt
```

### JSON Output to Stdout (Legacy)

```bash
docker-compose run --rm domain-expiry-checker python3 main.py --json > results.json
```

### Run Directly (Without Docker Compose)

```bash
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v /usr/bin/docker:/usr/bin/docker:ro \
  ciweb/domain-expiry-checker:latest \
  python3 main.py --days 30
```

## Command-Line Options

| Option        | Short | Description                                 | Default        |
| ------------- | ----- | ------------------------------------------- | -------------- |
| `--container` | `-c`  | Check specific WordPress container          | All containers |
| `--days`      | `-d`  | Days threshold for expiry warning           | 30             |
| `--output`    | `-o`  | Save results to file (.json, .csv, or .txt) | None           |
| `--dry-run`   |       | Test mode without WHOIS queries             | False          |
| `--verbose`   | `-v`  | Enable verbose logging                      | False          |
| `--json`      |       | Output results as JSON to stdout (legacy)   | False          |

## Sample Output

### Summary Report

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

  testsite.com (container: wp_testsite_com)
    Days remaining: 28
    Expiry date: 2026-02-18

================================================================================
```

### JSON Output

```json
{
  "checked": [
    {
      "container": "wp_example_com",
      "domain": "example.com",
      "base_domain": "example.com",
      "expiry_date": "2026-02-05",
      "days_until_expiry": 15,
      "status": "expiring_soon"
    }
  ],
  "expiring_soon": [
    {
      "container": "wp_example_com",
      "domain": "example.com",
      "base_domain": "example.com",
      "expiry_date": "2026-02-05",
      "days_until_expiry": 15,
      "status": "expiring_soon"
    }
  ],
  "expired": [],
  "errors": []
}
```

### CSV Output

```csv
Container,Domain,Base Domain,Expiry Date,Days Until Expiry,Status
wp_example_com,example.com,example.com,2026-02-05,15,expiring_soon
wp_testsite_com,testsite.com,testsite.com,2026-02-18,28,expiring_soon
wp_mysite_com,mysite.com,mysite.com,2026-06-15,145,ok
```

### Text Table Output

```
====================================================================================================
DOMAIN EXPIRY CHECK RESULTS
====================================================================================================

Total domains checked: 3
Expiring within 30 days: 2
Expired: 0
Errors: 0

====================================================================================================
ALL DOMAINS
====================================================================================================
Container                      Domain                         Expiry Date     Days       Status
----------------------------------------------------------------------------------------------------
wp_example_com                 example.com                    2026-02-05      15         🟡 EXPIRING_SOON
wp_testsite_com                testsite.com                   2026-02-18      28         🟡 EXPIRING_SOON
wp_mysite_com                  mysite.com                     2026-06-15      145        ✅ OK

====================================================================================================
```

## Automation with Cron

### Daily Check (7 AM)

Add to your crontab:

```bash
0 7 * * * cd /var/www/ciwebgroup/wp-hubstack/scripts/server/domain-expiry-notifications && docker-compose run --rm domain-expiry-checker >> /var/log/domain-expiry-check.log 2>&1
```

### Weekly Check with Email Notification

```bash
0 9 * * 1 cd /var/www/ciwebgroup/wp-hubstack/scripts/server/domain-expiry-notifications && docker-compose run --rm domain-expiry-checker | mail -s "Domain Expiry Report" admin@example.com
```

### Check Only Domains Expiring in 7 Days (Daily Alert)

```bash
0 8 * * * cd /var/www/ciwebgroup/wp-hubstack/scripts/server/domain-expiry-notifications && docker-compose run --rm domain-expiry-checker python3 main.py --days 7
```

## Exit Codes

- `0`: Success - no domains expiring soon or expired
- `1`: Warning - domains found that are expiring soon or already expired

Use these exit codes in scripts for conditional actions:

```bash
if ! docker-compose run --rm domain-expiry-checker; then
    echo "ACTION REQUIRED: Domains expiring soon!" | mail -s "ALERT: Domain Expiry" admin@example.com
fi
```

## WHOIS Lookup Methods

The script uses two methods for maximum compatibility:

1. **python-whois library** (Primary): More reliable parsing of WHOIS data
2. **System whois command** (Fallback): Works when python-whois fails

Both methods are included in the Docker image.

## Troubleshooting

### Container Not Finding Domains

Ensure your WordPress containers have the `WP_HOME` environment variable set:

```yaml
environment:
  - WP_HOME=https://example.com
```

### WHOIS Queries Failing

Some domain registrars have rate limits. If checking many domains, consider:

- Adding delays between queries
- Running checks less frequently
- Using `--dry-run` for testing

### Permission Denied on Docker Socket

Ensure the Docker socket is mounted with read permissions:

```yaml
volumes:
  - /var/run/docker.sock:/var/run/docker.sock:ro
```

## Integration with Other Scripts

Similar to [wp-update-suite](../wp-update-suite/), this script:

- Uses Docker inspection to discover WordPress installations
- Extracts configuration from environment variables
- Provides both human-readable and JSON output
- Supports dry-run mode for testing

## Development

### Local Development (Without Docker)

```bash
# Install dependencies
pip install -r requirements.txt

# Install whois utility
sudo apt-get install whois

# Run script
python3 main.py --dry-run -v
```

### Testing

```bash
# Test with dry-run
python3 main.py --dry-run -v

# Test specific container
python3 main.py --container wp_test_com --dry-run

# Test JSON output
python3 main.py --json --dry-run
```

## License

Part of the CI Web Group WP-Hubstack infrastructure.
