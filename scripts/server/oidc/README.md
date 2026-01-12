# fix-oidc-settings (dockerized)

This folder contains a dockerized Python implementation of the `fix-oidc-settings.sh` script.

Files:
- `fix_oidc_settings.py` — Python script that finds WordPress containers and updates the `openid_connect_generic_settings` option via WP-CLI.
- `Dockerfile` — Builds a small image with the Python script and Docker SDK.
- `docker-compose.yml` — Convenience compose to run the container with access to the host Docker socket and a backup directory (`./oidc_backups`).
- `requirements.txt` — Python dependencies (docker).

Usage examples:

Dry run (see what would be changed):

  docker-compose run --rm fix-oidc-settings --dry-run

Include only some containers (regex):

  docker-compose run --rm fix-oidc-settings --include "wp_airserv"

Run for real (writes backups to `./oidc_backups`):

  docker-compose run --rm fix-oidc-settings

Local mypy check for the OIDC script:

  ./run_mypy.sh

Notes:
- The container must have access to the Docker socket: the provided `docker-compose.yml` mounts `/var/run/docker.sock` and a local `./oidc_backups` directory for backups.
- The script uses the Docker SDK to call `container.exec_run(..., user='www-data')` to interact with WP-CLI; ensure containers have `wp` available and the `www-data` user exists.
- Set `CLIENT_ID` and `CLIENT_SECRET` via environment variables (for example, export them before running `docker-compose` or set them in the compose file). If they are not set, the script will use the original defaults from the shell script (suitable for internal testing but not for production).
- If you prefer, you can run the script directly on the host with `pip install docker` and `python fix_oidc_settings.py ...`.
