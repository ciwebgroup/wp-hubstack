# Site Optimizer CLI - Quick Start Guide

## Phase 2: Inventory Management ✅

The inventory system is now ready to import and manage your 548 sites across 33 servers.

## Setup

```bash
cd /var/www/ciwebgroup/wp-hubstack/scripts/server/site-optimizer

# Copy environment template
cp .env.example .env

# Build Docker image
docker-compose build
```

## Import Your Sites

### Option 1: From CSV

Create a CSV file with your sites:

```csv
domain,server,container_name,site_path
example.com,server01.example.com,wp_example_com,/var/opt/sites/example.com
test.com,server01.example.com,wp_test_com,/var/opt/sites/test.com
```

Import:
```bash
docker-compose run --rm site-optimizer inventory import --file /path/to/sites.csv
```

### Option 2: From JSON

Create a JSON file:

```json
{
  "sites": [
    {
      "domain": "example.com",
      "server": "server01.example.com",
      "container_name": "wp_example_com",
      "site_path": "/var/opt/sites/example.com"
    }
  ]
}
```

Import:
```bash
docker-compose run --rm site-optimizer inventory import --file /path/to/sites.json
```

## View Your Inventory

### List All Sites

```bash
# Table format (default)
docker-compose run --rm site-optimizer inventory list

# JSON format
docker-compose run --rm site-optimizer inventory list --format json

# Filter by server
docker-compose run --rm site-optimizer inventory list --server server01.example.com

# Filter by tier
docker-compose run --rm site-optimizer inventory list --tier 2
```

### List All Servers

```bash
# All servers
docker-compose run --rm site-optimizer inventory list-servers

# Filter by capacity status
docker-compose run --rm site-optimizer inventory list-servers --status over_capacity

# JSON format
docker-compose run --rm site-optimizer inventory list-servers --format json
```

### View Statistics

```bash
docker-compose run --rm site-optimizer inventory stats
```

Output:
```
Inventory Statistics

Sites:
  Total: 548
  Tier 1: 15
  Tier 2: 120
  Tier 3: 350
  Unassigned: 63

Servers:
  Total: 33
  Under Capacity: 5
  Optimal: 10
  Over Capacity: 15
  Critical: 3

Average sites per server: 16.6
```

## Example Workflow

```bash
# 1. Import your sites
docker-compose run --rm site-optimizer inventory import --file sites.csv

# 2. View statistics
docker-compose run --rm site-optimizer inventory stats

# 3. List over-capacity servers
docker-compose run --rm site-optimizer inventory list-servers --status over_capacity

# 4. View sites on a specific server
docker-compose run --rm site-optimizer inventory list --server server01.example.com
```

## Data Storage

All inventory data is stored in `data/inventory.json` and persists between runs.

## Next Steps

Once your inventory is imported, you can:

1. **Analyze traffic** (Phase 3) - Pull Google Analytics data
2. **Classify sites** (Phase 4) - Auto-assign tiers based on traffic
3. **Plan migrations** (Phase 5) - Optimize server distribution
4. **Deploy configs** (Phase 6) - Apply tier configurations

## Testing

Run the test suite:

```bash
# All tests
make test

# With coverage
make test-cov

# Type checking
make type-check
```

## Troubleshooting

### Import fails with validation errors

Check that your CSV/JSON has the required fields:
- `domain` (required)
- `server` (required)
- `container_name` (optional)
- `site_path` (optional)

### No sites showing up

Make sure you've imported data first:
```bash
docker-compose run --rm site-optimizer inventory stats
```

If total is 0, import your sites.
