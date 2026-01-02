# Traefik Config Manager

Type-safe Python CLI for managing Traefik docker-compose configurations with automatic backup and rollback support.

## Features

- **Type-safe**: Pydantic models + MyPy strict mode
- **Dry-run**: Preview changes before applying
- **Auto-backup**: Creates timestamped backups before modifications
- **Rollback**: Restore from backup and restart containers
- **Comment preservation**: Uses ruamel.yaml to preserve YAML comments

## Quick Start

### Build Docker Image

```bash
docker compose -f docker-compose.manager.yml build
```

### Add Configuration

```bash
# Dry-run: preview changes
docker compose -f docker-compose.manager.yml run --rm traefik-config \
    add --traefik-dir /traefik --config /traefik/additions.yaml --dry-run

# Apply changes
docker compose -f docker-compose.manager.yml run --rm traefik-config \
    add --traefik-dir /traefik --config /traefik/additions.yaml
```

### Rollback

```bash
# List available backups
docker compose -f docker-compose.manager.yml run --rm traefik-config \
    list-backups --traefik-dir /traefik

# Rollback to latest backup
docker compose -f docker-compose.manager.yml run --rm traefik-config \
    rollback --traefik-dir /traefik
```

### Show Current Config

```bash
docker compose -f docker-compose.manager.yml run --rm traefik-config \
    show --traefik-dir /traefik
```

## CLI Commands

| Command | Description |
|---------|-------------|
| `add` | Add configuration from YAML file |
| `rollback` | Restore latest backup and restart containers |
| `list-backups` | List all available backups |
| `show` | Show current configuration summary |

## Additions YAML Format

```yaml
traefik:
  command:
    - "--api.insecure=true"
    - "--entrypoints.metrics.address=:8083"
  ports:
    - "8082:8082"
  volumes:
    - "./dynamic:/etc/traefik/dynamic:ro"
  labels:
    - "traefik.http.middlewares.custom.headers.customrequestheaders.X-Custom=true"
  environment:
    CUSTOM_VAR: "value"
```

## Development

### Run MyPy Type Checks

```bash
docker compose -f docker-compose.manager.yml run --rm traefik-config \
    sh -c "mypy src/ --strict"
```

### Run Tests

```bash
docker compose -f docker-compose.manager.yml run --rm traefik-config \
    sh -c "pytest tests/"
```

## Backup Files

Backups are created with the pattern:
```
docker-compose.yml.backup.{YYYYMMDD_HHMMSS}
```

Example: `docker-compose.yml.backup.20260102_113000`
