# Site Optimizer CLI

A Dockerized Python CLI application for managing resource optimization across 548 WordPress sites on 33 servers.

## Features

- **Traffic Analysis**: Pull data from Google Analytics API
- **Tier Classification**: Auto-assign sites to performance tiers (1, 2, 3)
- **Migration Planning**: Optimize server density to ~16 sites/server
- **Deployment Orchestration**: Generate and execute deployment scripts
- **State Tracking**: Monitor deployment progress and rollback capability

## Architecture

```
site-optimizer/
├── src/
│   ├── cli.py              # Main CLI entry point
│   ├── commands/           # CLI command implementations
│   ├── services/           # Business logic services
│   ├── models/             # Pydantic data models
│   └── utils/              # Utilities and configuration
├── data/                   # Persistent data storage
├── credentials/            # API credentials (gitignored)
└── tests/                  # Test suite
```

## Quick Start

### 1. Setup

```bash
# Copy environment template
cp .env.example .env

# Edit configuration
nano .env

# Add Google Analytics credentials
cp /path/to/ga-service-account.json credentials/
```

### 2. Build Docker Image

```bash
docker-compose build
```

### 3. Run CLI

```bash
# Show help
docker-compose run --rm site-optimizer --help

# List command groups
docker-compose run --rm site-optimizer inventory --help
docker-compose run --rm site-optimizer analyze --help
docker-compose run --rm site-optimizer classify --help
docker-compose run --rm site-optimizer plan --help
docker-compose run --rm site-optimizer deploy --help
```

## Usage Examples

### Inventory Management

```bash
# Import site inventory from CSV
docker-compose run --rm site-optimizer inventory import --file sites.csv

# List all sites
docker-compose run --rm site-optimizer inventory list

# Show server distribution
docker-compose run --rm site-optimizer inventory servers
```

### Traffic Analysis

```bash
# Fetch traffic data from Google Analytics
docker-compose run --rm site-optimizer analyze fetch

# Show traffic for specific site
docker-compose run --rm site-optimizer analyze site example.com

# View traffic summary
docker-compose run --rm site-optimizer analyze summary
```

### Tier Classification

```bash
# Auto-classify all sites
docker-compose run --rm site-optimizer classify auto

# Manually set tier for a site
docker-compose run --rm site-optimizer classify set example.com 2

# Review classification
docker-compose run --rm site-optimizer classify review
```

### Migration Planning

```bash
# Analyze current capacity
docker-compose run --rm site-optimizer plan analyze

# Generate migration plan
docker-compose run --rm site-optimizer plan generate --target-density 16

# Review plan
docker-compose run --rm site-optimizer plan review <plan_id>
```

### Deployment

```bash
# Generate deployment scripts
docker-compose run --rm site-optimizer deploy generate

# Preview deployment for a server
docker-compose run --rm site-optimizer deploy preview server01.example.com

# Execute deployment (dry-run by default)
docker-compose run --rm site-optimizer deploy execute server01.example.com

# Execute for real
docker-compose run --rm site-optimizer deploy execute server01.example.com --no-dry-run
```

## Configuration

### Environment Variables

See `.env.example` for all available configuration options:

- `GA_PROPERTY_ID`: Google Analytics property ID
- `GA_CREDENTIALS_PATH`: Path to GA service account JSON
- `TIER1_MIN_VISITORS`: Minimum daily visitors for Tier 1 (default: 10000)
- `TIER2_MIN_VISITORS`: Minimum daily visitors for Tier 2 (default: 1000)
- `DRY_RUN`: Enable dry-run mode (default: true)
- `PARALLEL_DEPLOYMENTS`: Number of parallel deployments (default: 5)

### Tier Thresholds

| Tier | Traffic | Sites/Server | Workers | Memory | Peak RAM/Site |
|------|---------|--------------|---------|--------|---------------|
| 1 | High (>10k/day) | 2-3 | 15 | 512M | ~4-5GB |
| 2 | Medium (1k-10k/day) | 5-7 | 10 | 384M | ~2.5-3GB |
| 3 | Low (<1k/day) | 10-20 | 5 | 256M | ~1-1.5GB |

## Development

### Type Checking with MyPy

```bash
# Run MyPy type checker
docker-compose run --rm site-optimizer sh -c "mypy src/"
```

### Running Tests

```bash
# Run test suite
docker-compose run --rm site-optimizer sh -c "pytest"

# With coverage
docker-compose run --rm site-optimizer sh -c "pytest --cov=src --cov-report=html"
```

### Code Formatting

```bash
# Format with Black
docker-compose run --rm site-optimizer sh -c "black src/"

# Lint with Ruff
docker-compose run --rm site-optimizer sh -c "ruff check src/"
```

## Data Models

### Site Model
```python
{
    "domain": "example.com",
    "server": "server01.example.com",
    "current_tier": 2,
    "assigned_tier": 2,
    "traffic": {
        "daily_visitors": 5000,
        "page_views": 15000,
        "last_updated": "2026-01-02T08:00:00"
    }
}
```

### Server Model
```python
{
    "hostname": "server01.example.com",
    "specs": {
        "cpu_cores": 8,
        "ram_gb": 16
    },
    "sites": ["example.com", "test.com"],
    "capacity": {
        "current_sites": 25,
        "recommended_max": 16,
        "status": "over_capacity"
    }
}
```

## Project Status

### Phase 1: Foundation ✅
- [x] Project structure
- [x] Docker setup
- [x] Data models (Site, Server, Deployment)
- [x] Configuration management
- [x] CLI framework

### Phase 2: Traffic Analysis (In Progress)
- [ ] Google Analytics integration
- [ ] Traffic data fetcher
- [ ] Analysis commands

### Phase 3: Tier Classification (Planned)
- [ ] Classification logic
- [ ] Auto-classification
- [ ] Manual overrides

### Phase 4: Migration Planning (Planned)
- [ ] Capacity analysis
- [ ] Migration planner
- [ ] Plan generator

### Phase 5: Deployment (Planned)
- [ ] Deployment generator
- [ ] SSH execution
- [ ] Progress tracking

## Type Safety

This project uses **MyPy strict mode** for comprehensive type checking:

- Full type hints on all functions and methods
- Pydantic models for runtime validation
- No `Any` types allowed
- Strict null checking

## License

Internal tool for CIWebGroup infrastructure management.

## Support

For issues or questions, contact the infrastructure team.
