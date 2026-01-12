#!/usr/bin/env python3
"""Fix OIDC Settings for WordPress Docker Containers (dockerized Python)

This script mirrors the behavior of the original bash script but runs
as a containerized Python tool and uses the Docker SDK to interact with
the docker daemon via the socket.

Usage (inside container):
  python fix_oidc_settings.py [--dry-run] [--include PATTERN] [--exclude PATTERN]

The container should be run with the Docker socket mounted and an optional
backup directory mounted to /data/backups. Example docker-compose.yml is
provided alongside this script.
"""

from __future__ import annotations
import argparse
import json
import os
import re
import sys
import time
from datetime import datetime
from typing import List, Optional, Tuple, TYPE_CHECKING

if TYPE_CHECKING:
    # Imported only for type checking to avoid importing heavy docker types at runtime
    # Avoid importing DockerClient (not always exposed to type checkers); only use Container here
    from docker.models.containers import Container

# Colors
RED = '\033[0;31m'
GREEN = '\033[0;32m'
YELLOW = '\033[1;33m'
BLUE = '\033[0;34m'
NC = '\033[0m'

OIDC_SETTINGS = {
    "login_type": "button",
    "scope": "openid email profile offline_access",
    "client_id": "ciwg_wordpress_sso_client_id",
    "client_secret": "ciwg_wordpress_sso_client_secret",
    "endpoint_login": "https://sso.ciwgserver.com/application/o/authorize/",
    "endpoint_userinfo": "https://sso.ciwgserver.com/application/o/userinfo/",
    "endpoint_token": "https://sso.ciwgserver.com/application/o/token/",
    "endpoint_end_session": "https://sso.ciwgserver.com/application/o/wordpress-sso/end-session/",
    "acr_values": "",
    "enforce_privacy": 0,
    "link_existing_users": 1,
    "create_if_does_not_exist": 1,
    "redirect_user_back": 1,
    "redirect_on_logout": 0,
    "enable_logging": 1,
    "log_limit": 1000,
}

BACKUP_DIR = os.environ.get("BACKUP_DIR", "/data/backups")
DOCKER_SOCKET = os.environ.get("DOCKER_SOCKET", "/var/run/docker.sock")

# Delay to wait for exec result when needed
EXEC_WAIT = 1.0


def log_info(*args):
    print(f"{BLUE}[INFO]{NC}", *args)


def log_success(*args):
    print(f"{GREEN}[SUCCESS]{NC}", *args)


def log_warning(*args):
    print(f"{YELLOW}[WARNING]{NC}", *args)


def log_error(*args):
    print(f"{RED}[ERROR]{NC}", *args)


# Allow overriding client credentials via environment variables
CLIENT_ID = os.environ.get('CLIENT_ID')
CLIENT_SECRET = os.environ.get('CLIENT_SECRET')
if CLIENT_ID:
    OIDC_SETTINGS['client_id'] = CLIENT_ID
if CLIENT_SECRET:
    OIDC_SETTINGS['client_secret'] = CLIENT_SECRET

try:
    import docker
except Exception:
    log_error("Missing dependency 'docker' (Python SDK). Install with: pip install docker")
    raise

client = docker.from_env()  # type: ignore[attr-defined]


def get_wordpress_containers() -> List["Container"]:
    # Find containers whose name contains 'wp_' or 'wordpress'
    out: List["Container"] = []
    for c in client.containers.list():
        name = c.name
        if re.search(r'wp_|wordpress', name):
            out.append(c)
    return out


def container_exec(container: "Container", cmd: str, user: Optional[str] = None, timeout: int = 30) -> Tuple[int, str, str]:
    try:
        exec_res = container.exec_run(cmd, user=user, demux=True)
        # exec_res can be a tuple: (exit_code, (stdout, stderr))
        if isinstance(exec_res, tuple):
            exit_code, out_err = exec_res
            if out_err is None:
                return exit_code, "", ""
            out, err = out_err
            stdout = out.decode('utf-8') if out else ''
            stderr = err.decode('utf-8') if err else ''
            return exit_code, stdout, stderr
        else:
            # older sdk: with .output
            exit_code = exec_res.exit_code
            output = exec_res.output.decode('utf-8') if exec_res.output else ''
            return exit_code, output, ''
    except Exception as e:
        return 1, '', str(e)


def check_wp_cli(container: "Container") -> bool:
    code, out, err = container_exec(container, "which wp", user='www-data')
    return code == 0


def get_current_settings(container: "Container") -> Optional[dict]:
    code, out, err = container_exec(container, "wp option get openid_connect_generic_settings --format=json", user='www-data')
    if code != 0:
        return None
    out = out.strip()
    if not out or out in ('null', 'false'):
        return None
    try:
        return json.loads(out)
    except Exception:
        # if not valid json, return None
        return None


def backup_current_settings(container: "Container") -> Optional[str]:
    data = get_current_settings(container)
    if not data:
        return None
    os.makedirs(BACKUP_DIR, exist_ok=True)
    ts = datetime.utcnow().strftime('%Y%m%d_%H%M%S')
    fname = f"oidc_backup_{container.name}_{ts}.json"
    path = os.path.join(BACKUP_DIR, fname)
    try:
        with open(path, 'w') as fh:
            json.dump(data, fh, indent=2)
        return path
    except Exception as e:
        log_error("Failed to write backup:", e)
        return None


def update_oidc_settings(container: "Container", dry_run: bool) -> bool:
    log_info(f"Processing container: {container.name}")
    if not check_wp_cli(container):
        log_warning(f"WP-CLI not found in container {container.name}, skipping...")
        return False

    current = get_current_settings(container)
    if current:
        log_info("Found existing OIDC settings")
        backup = backup_current_settings(container)
        if backup:
            log_success("Backup saved to:", backup)
    else:
        log_info("No existing OIDC settings found (will create new)")

    if dry_run:
        log_warning(f"[DRY RUN] Would update OIDC settings for {container.name}")
        print(json.dumps(OIDC_SETTINGS, indent=2))
        return True

    # Apply settings
    payload = json.dumps(OIDC_SETTINGS)
    # use printf to preserve content in shell; with docker SDK we run wp directly
    cmd = f"wp option update openid_connect_generic_settings '{payload}' --format=json"
    code, out, err = container_exec(container, cmd, user='www-data')
    if code == 0:
        log_success("OIDC settings updated successfully!")
        # verify
        new = get_current_settings(container)
        client_id = new.get('client_id') if new else None
        if client_id:
            log_success(f"Verification passed - client_id: {str(client_id)[:20]}...")
            return True
        else:
            log_error("Verification failed - settings may not have been applied correctly")
            return False
    else:
        log_error("Failed to update OIDC settings")
        log_error(err or out)
        return False


def discover_and_process(include: Optional[str], exclude: Optional[str], dry_run: bool) -> Tuple[int, int, int]:
    log_info("Discovering WordPress containers...")
    containers = get_wordpress_containers()
    if not containers:
        log_warning("No WordPress containers found")
        return 0, 0, 0

    log_info(f"Found {len(containers)} WordPress container(s)")

    processed = skipped = failed = 0
    patt_inc = re.compile(include) if include else None
    patt_exc = re.compile(exclude) if exclude else None

    for c in containers:
        name = c.name
        if patt_inc and not patt_inc.search(name):
            log_info(f"Skipping container: {name} (not in include)")
            skipped += 1
            continue
        if patt_exc and patt_exc.search(name):
            log_info(f"Skipping container: {name} (excluded)")
            skipped += 1
            continue
        ok = update_oidc_settings(c, dry_run=dry_run)
        if ok:
            processed += 1
        else:
            failed += 1

    return len(containers), processed, failed


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description='Fix OIDC settings for WordPress Docker containers')
    p.add_argument('--dry-run', action='store_true', help='Show what would be done without making changes')
    p.add_argument('--include', help='Only process containers matching this pattern', default='')
    p.add_argument('--exclude', help='Skip containers matching this pattern', default='')
    return p.parse_args()


def main():
    args = parse_args()
    # quick dependency check: can we connect to docker socket?
    try:
        client.ping()
    except Exception as e:
        log_error("Cannot connect to Docker daemon. Ensure the socket is mounted and accessible.")
        log_error(e)
        sys.exit(1)

    log_info("OIDC Settings Fix Tool")
    log_info(f"Dry Run: {args.dry_run}")
    if args.include:
        log_info(f"Include Pattern: {args.include}")
    if args.exclude:
        log_info(f"Exclude Pattern: {args.exclude}")
    log_info(f"Backup dir: {BACKUP_DIR}")

    if not CLIENT_ID or not CLIENT_SECRET:
        log_warning("CLIENT_ID or CLIENT_SECRET not set via env; using defaults (not secure for production)")

    total, processed, failed = discover_and_process(args.include, args.exclude, args.dry_run)

    print("==================================")
    print("Summary")
    print("==================================")
    print(f"Total containers found: {total}")
    print(f"Processed: {processed}")
    print(f"Failed: {failed}")

    if args.dry_run:
        log_warning("This was a DRY RUN - no changes were made")

    if failed > 0:
        sys.exit(1)
    sys.exit(0)


if __name__ == '__main__':
    main()
