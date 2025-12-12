# WP Update Suite

A Python-based WordPress update automation tool for managing multiple WordPress Docker containers with support for plugins, themes, core updates, and Elementor/Rank Math database migrations.

## Features

- **Docker-based WordPress management**: Automatically detect and update all `wp_*` containers
- **Smart Core Updates**: Uses docker-compose to pull latest images and restart containers
- **Plugin & Theme Updates**: Selective or batch updates with dependency-aware ordering for Rank Math and Elementor
- **Database Schema Updates**: Run `wp core update-db` and `wp elementor update db` automatically
- **Backup Support**: Create SQL backups before updates
- **Dry Run Mode**: Preview changes before applying
- **Flexible Execution**: Run locally or via Docker with managed dependencies

## Requirements

### Local Installation
- Python 3.8+
- Docker and docker-compose (or docker compose v2)
- Access to Docker socket (`/var/run/docker.sock`)

### Dockerized Installation
- Docker and docker-compose (or docker compose v2)
- Access to Docker socket

## Installation

### Option 1: Local Python Installation

```bash
# Install dependencies
pip install -r requirements.txt

# Run directly
python3 main.py --help
```

### Option 2: Docker Installation

```bash
# Build the image
docker compose build

# Run via docker compose
docker compose run --rm wp-updater --help

# Or use the convenience script
./run.sh docker
```

## Usage

### Basic Commands

```bash
# Interactive mode (select container and updates)
python3 main.py

# Update all containers non-interactively
python3 main.py --all-containers --non-interactive --update-plugins all --update-themes all

# Update specific container with dry run
python3 main.py --container-name wp_sitename --dry-run --update-core --update-plugins all

# Check database schema after updates
python3 main.py --container-name wp_sitename --check-update-db-schema

# Skip Rank Math and Elementor special handling
python3 main.py --skip-rank-math-elementor-update
```

### Via Docker

```bash
# Run with docker mode via run.sh
./run.sh docker

# Or directly via docker compose
docker compose run --rm wp-updater --all-containers --non-interactive --update-plugins all
```

### Command Line Options

- `--container-name, -c`: Target specific container
- `--all-containers`: Update all wp_* containers
- `--non-interactive, -n`: Run without prompts
- `--update-core`: Update WordPress core via docker-compose image pull
- `--update-plugins, -p`: Update plugins (all/none/1,3,5/plugin-slug)
- `--update-themes, -t`: Update themes (all/none/1,3,5/theme-slug)
- `--check-update-db-schema`: Run wp core update-db after updates
- `--dry-run`: Show what would happen without making changes
- `--no-backup`: Skip backup creation
- `--skip-rank-math-elementor-update`: Skip special plugin ordering
- `--restart-docker`: Restart docker-compose stack after updates
- `--mirror-wp-assets`: Mirror plugins/themes to host (requires external script)
- `--verbose, -v`: Increase output verbosity

## How It Works

### Core Updates
1. Locates `docker-compose.yml` in the container's working directory
2. Updates the service image to `ghcr.io/ciwebgroup/advanced-wordpress:latest` (if different)
3. Runs `docker compose pull && docker compose down && docker compose up -d`
4. Falls back to `wp core update` if no compose file exists

### Plugin Updates
1. Special handling for Rank Math and Elementor plugins (ordered updates)
2. Runs `wp elementor update db` after Elementor plugin updates
3. Flushes cache after all plugin updates complete

### Database Updates
- `wp core update-db` for WordPress schema
- `wp elementor update db` for Elementor-specific schema

## Docker Compose Integration

The updater integrates with your WordPress container's `docker-compose.yml`:

```yaml
services:
  wp_sitename:
    image: ghcr.io/ciwebgroup/advanced-wordpress:latest
    # ... other config
```

The script will:
- Parse the YAML file (using ruamel.yaml or PyYAML)
- Update the image reference if needed
- Pull the new image and restart the container

## Backup Strategy

Backups are created in `/var/opt/{site_url}/www/backups/`:
- SQL database exports with timestamps
- Configurable with `--no-backup` or `--skip-backups`

## Logging

- Standard output shows progress with emojis (🔄 updating, ✅ success, ❌ error, ℹ️ info)
- Verbose mode: `--verbose` or `-v`
- When running via `run.sh`, logs to `/root/logs/wp-update-suite.log`

## Examples

### Update all containers with full automation
```bash
python3 main.py --all-containers --non-interactive \
  --update-core --update-plugins all --update-themes all \
  --check-update-db-schema
```

### Update specific container interactively
```bash
python3 main.py --container-name wp_example
```

### Dry run to preview changes
```bash
python3 main.py --all-containers --dry-run \
  --update-plugins all --update-themes all
```

### Via cron (scheduled updates)
```bash
# Add to crontab
0 3 * * * /var/opt/scripts/wp-update-suite/run.sh >> /root/logs/wp-update-suite.log 2>&1
```

## Troubleshooting

### YAML Parser Not Available
Install dependencies:
```bash
pip install ruamel.yaml PyYAML
```

### Docker Socket Permission Denied
Ensure the user has access to `/var/run/docker.sock`:
```bash
sudo usermod -aG docker $USER
```

### Compose Commands Fail
The script tries `docker compose` (v2) first, then falls back to `docker-compose` (v1).

## Development

### Project Structure
```
wp-update-suite/
├── main.py              # Main updater script
├── run.sh               # Convenience runner script
├── requirements.txt     # Python dependencies
├── Dockerfile           # Docker image definition
├── docker-compose.yml   # Docker compose config
└── README.md           # This file
```

### Testing
```bash
# Dry run is your friend
python3 main.py --dry-run --all-containers --update-plugins all
```

## License

MIT License - see LICENSE file for details

## Contributing

Issues and pull requests welcome!
