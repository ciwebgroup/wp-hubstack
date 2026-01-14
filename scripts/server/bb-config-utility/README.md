bb-config-utility

Small utility to add site-scoped Traefik headers for Beaver Builder preview.

Usage (local):
- Build and run via Docker Compose in the directory:
  docker-compose build
  docker-compose run --rm bb-config-utility --traefik-container traefik --dry-run

Flags:
- --traefik-container NAME  : name of traefik container (required unless --traefik-config path provided)
- --traefik-config PATH     : override path to traefik working dir (skips docker inspect lookup)
- --site-containers LIST    : comma-separated site container names (defaults to containers starting with wp_)
- --include LIST            : comma-separated container names to include (applied after site discovery)
- --exclude LIST            : comma-separated container names to exclude
- --dry-run                 : prints planned changes but does not modify files

