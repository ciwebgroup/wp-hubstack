#!/usr/bin/env python3
"""varnish_utils.py
Combined Varnish testing and cache-clearing utility.
Features:
  - test: run cache checks against one or more sites (supports --sites as list or file)
  - clear: issue varnish bans or restart varnish (actions: host,url,regex,list,full)

This tool expects Docker CLI to be available (it will run commands such as
`docker exec varnish varnishadm ...` and `docker restart varnish`) — in the
dockerized environment we'll mount /var/run/docker.sock so the container can
control the host Docker service.
"""

from __future__ import annotations
import argparse
import shlex
import subprocess
import sys
import time
import re
from typing import List

try:
    import requests
except Exception:
    print("Missing dependency 'requests'. Install with pip install requests", file=sys.stderr)
    raise

import os
import shutil
from datetime import datetime

# YAML helpers: prefer ruamel.yaml for round-trip, fall back to PyYAML
try:
    from ruamel.yaml import YAML
    _yaml = YAML()
    def load_yaml(path):
        with open(path, 'r') as fh:
            return _yaml.load(fh) or {}
    def dump_yaml(data, path):
        with open(path, 'w') as fh:
            _yaml.dump(data, fh)
except Exception:
    try:
        import yaml
    except Exception:
        print("Missing dependency 'ruamel.yaml' or 'PyYAML'. Install with pip install ruamel.yaml or pip install pyyaml", file=sys.stderr)
        raise
    def load_yaml(path):
        with open(path, 'r') as fh:
            return yaml.safe_load(fh) or {}
    def dump_yaml(data, path):
        with open(path, 'w') as fh:
            yaml.safe_dump(data, fh, default_flow_style=False)


def run(cmd: str, check: bool = True) -> subprocess.CompletedProcess:
    print(f"+ {cmd}")
    completed = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if completed.returncode != 0 and check:
        print(completed.stdout + completed.stderr, file=sys.stderr)
        raise SystemExit(completed.returncode)
    return completed


def parse_sites_arg(arg: str) -> List[str]:
    sites = []
    if not arg:
        return sites
    import os
    if os.path.isfile(arg):
        with open(arg, "r") as fh:
            for line in fh:
                s = line.strip()
                if not s or s.startswith('#'):
                    continue
                sites.append(s)
    else:
        for part in arg.split(','):
            p = part.strip()
            if p:
                sites.append(p)
    return sites


def extract_host(site: str) -> str:
    if site.startswith('http://') or site.startswith('https://'):
        # remove scheme and path
        host = re.sub(r'^https?://', '', site)
        host = host.split('/', 1)[0]
        return host
    return site


def docker_container_exists(name: str) -> bool:
    cp = subprocess.run(f"docker ps -q -f name=^/{shlex.quote(name)}$", shell=True, capture_output=True, text=True)
    return bool(cp.stdout.strip())


def cmd_varnishadm(args: str) -> subprocess.CompletedProcess:
    return run(f"docker exec varnish varnishadm {shlex.quote(args)}")


def cmd_vstat(patterns: List[str]) -> subprocess.CompletedProcess:
    args = ' '.join(['-f ' + p for p in patterns])
    return run(f"docker exec varnish varnishstat -1 {args}")


def action_test(sites: List[str]):
    print("\n== Varnish / environment checks ==")
    run("docker ps --filter \"name=varnish\" --format \"table {{.Names}}\\t{{.Status}}\"")
    # backend list
    try:
        cmd_varnishadm('backend.list')
    except SystemExit:
        print("Could not query varnish backend.list (varnish may not be running)")
    # stats before
    try:
        cmd_vstat(['MAIN.cache_hit', 'MAIN.cache_miss', 'MAIN.client_req'])
    except SystemExit:
        print("Could not query varnishstat (varnish may not be running)")

    if not sites:
        sites = ["theadvisoryib.stg.ciwgserver.com"]

    for idx, site in enumerate(sites, start=1):
        print(f"\n== Site #{idx}: {site} ==")
        host = extract_host(site)
        if site.startswith('http'):
            url = site
        else:
            url = f"https://{site}"

        # First request
        print("-- First request (expect MISS)")
        try:
            r = requests.head(url, timeout=10, allow_redirects=True, verify=False)
            print(f"HTTP/{r.raw.version if hasattr(r.raw, 'version') else '1.1'} {r.status_code}")
            print(' | '.join([f"{k}: {v}" for k, v in r.headers.items() if k.lower() in ('x-cache', 'cache-control', 'age')] ))
        except Exception as e:
            print(f"HEAD error: {e}")
        st = time.time()
        try:
            r2 = requests.get(url, timeout=20, verify=False)
            elapsed = time.time() - st
            print(f"Response Time: {elapsed:.3f}s")
            if 'X-Cache' in r2.headers:
                print(f"X-Cache: {r2.headers.get('X-Cache')}")
        except Exception as e:
            print(f"GET error: {e}")

        # Second request
        print("-- Second request (expect HIT)")
        try:
            r3 = requests.head(url, timeout=10, allow_redirects=True, verify=False)
            print(f"HTTP/{r3.status_code}")
            print(' | '.join([f"{k}: {v}" for k, v in r3.headers.items() if k.lower() in ('x-cache', 'cache-control', 'age')] ))
        except Exception as e:
            print(f"HEAD error: {e}")
        st = time.time()
        try:
            r4 = requests.get(url, timeout=20, verify=False)
            elapsed = time.time() - st
            print(f"Response Time: {elapsed:.3f}s")
        except Exception as e:
            print(f"GET error: {e}")

        # Direct varnish internal access for Host header
        print("-- Direct Varnish internal request (using docker exec wget)")
        try:
            run(f"docker exec varnish wget -q -O- --header=\"Host: {host}\" http://localhost/ | head -n 5", check=False)
        except SystemExit:
            print("Internal wget failed")

        # Static file check (best effort)
        print("-- Static file header check (best-effort)")
        static_url = url.rstrip('/') + '/wp-content/themes/style.css'
        try:
            r5 = requests.head(static_url, timeout=10, verify=False)
            print(' | '.join([f"{k}: {v}" for k, v in r5.headers.items() if k.lower() in ('cache-control', 'content-type', 'x-cache')] ))
        except Exception:
            print("No static file headers found (adjust static path if needed)")

    print('\n-- Aggregate stats after requests --')
    try:
        cmd_vstat(['MAIN.cache_hit', 'MAIN.cache_miss', 'MAIN.client_req'])
    except SystemExit:
        pass


def action_clear(sites: List[str], action: str, url_path: str, pattern: str, dry_run: bool, assume_yes: bool):
    if action == 'list':
        run("docker exec varnish varnishadm ban.list")
        return
    if action == 'full':
        if not docker_container_exists('varnish'):
            print("Varnish container not found")
            return
        if not assume_yes:
            ok = input("Restart varnish container now? This will clear all cache and cause a brief interruption. [y/N] ")
            if not ok.lower().startswith('y'):
                print("Aborted")
                return
        cmd = "docker restart varnish"
        if dry_run:
            print("DRY RUN: ", cmd)
        else:
            run(cmd)
        return

    # host/url/regex
    if not docker_container_exists('varnish'):
        print("Varnish container not found")
        return
    if not sites:
        sites = ["theadvisoryib.stg.ciwgserver.com"]
    for site in sites:
        host = extract_host(site)
        if action == 'host':
            cmd = f"docker exec varnish varnishadm \"ban req.http.host == '{host}'\""
        elif action == 'url':
            if not url_path:
                print('--url required for action=url', file=sys.stderr)
                continue
            cmd = f"docker exec varnish varnishadm \"ban req.http.host == '{host}' && req.url == '{url_path}'\""
        elif action == 'regex':
            if not pattern:
                print('--pattern required for action=regex', file=sys.stderr)
                continue
            cmd = f"docker exec varnish varnishadm \"ban req.http.host == '{host}' && req.url ~ '{pattern}'\""
        if dry_run:
            print("DRY RUN: ", cmd)
        else:
            run(cmd)


def action_deploy(dc_config_path: str, target_dc_config_path: str, dry_run: bool, assume_yes: bool):
    print("\n== Deploy Varnish service into Docker Compose ==")
    if not os.path.isfile(dc_config_path):
        print(f"dc-config file not found: {dc_config_path}", file=sys.stderr)
        return
    if not os.path.isfile(target_dc_config_path):
        print(f"target file not found: {target_dc_config_path}", file=sys.stderr)
        return
    try:
        services_src = load_yaml(dc_config_path) or {}
    except Exception as e:
        print(f"Failed to load dc-config: {e}", file=sys.stderr)
        return
    if 'services' in services_src and isinstance(services_src['services'], dict):
        services = services_src['services'] or {}
    else:
        # if the file is a single service mapping, use it directly (allow either style)
        services = services_src or {}
        # remove top-level version key if present
        services = {k: v for k, v in services.items() if k != 'version'}
    if not services:
        print("No services found in dc-config", file=sys.stderr)
        return
    try:
        target = load_yaml(target_dc_config_path) or {}
    except Exception as e:
        print(f"Failed to load target dc-config: {e}", file=sys.stderr)
        return
    target_services = target.get('services', {}) or {}
    collisions = [name for name in services if name in target_services]
    if collisions and not assume_yes:
        print(f"Service(s) {', '.join(collisions)} already exist in target: {target_dc_config_path}")
        ok = input("Overwrite them? [y/N] ")
        if not ok.lower().startswith('y'):
            print("Aborted")
            return
    # Backup
    ts = datetime.utcnow().strftime('%Y%m%dT%H%M%SZ')
    backup_path = f"{target_dc_config_path}.bak.{ts}"
    try:
        shutil.copy2(target_dc_config_path, backup_path)
    except Exception as e:
        print(f"Failed to create backup: {e}", file=sys.stderr)
        return
    print(f"Backed up {target_dc_config_path} -> {backup_path}")
    # Merge
    merged_services = dict(target_services)
    merged_services.update(services)
    target['services'] = merged_services
    if dry_run:
        print("DRY RUN: would write merged services into target (not writing file).")
        return
    try:
        dump_yaml(target, target_dc_config_path)
    except Exception as e:
        print(f"Error writing target file: {e}", file=sys.stderr)
        shutil.copy2(backup_path, target_dc_config_path)
        raise
    # Validate docker compose
    cwd = os.path.dirname(os.path.abspath(target_dc_config_path)) or '.'
    cmd = f"docker compose -f {shlex.quote(target_dc_config_path)} config -q"
    print(f"+ {cmd}")
    cp = subprocess.run(cmd, shell=True, capture_output=True, text=True, cwd=cwd)
    if cp.returncode != 0:
        print("docker compose config failed, rolling back", file=sys.stderr)
        print(cp.stdout + cp.stderr, file=sys.stderr)
        try:
            shutil.copy2(backup_path, target_dc_config_path)
        except Exception as e:
            print(f"Failed to restore backup: {e}", file=sys.stderr)
        raise SystemExit(cp.returncode)
    print("Deploy successful; docker compose config validated.")


def main():
    parser = argparse.ArgumentParser(description='Varnish utils: test, clear cache, and deploy varnish service')
    sub = parser.add_subparsers(dest='cmd', required=True)

    # test
    p_test = sub.add_parser('test', help='Run varnish cache tests against sites')
    p_test.add_argument('--sites', help='Comma-separated list or file path', default='')

    # clear
    p_clear = sub.add_parser('clear', help='Clear varnish cache (ban or restart)')
    p_clear.add_argument('--sites', help='Comma-separated list or file path', default='')
    p_clear.add_argument('--action', choices=['host', 'url', 'regex', 'list', 'full'], default='host')
    p_clear.add_argument('--url', dest='url_path', help='URL path for action=url')
    p_clear.add_argument('--pattern', help='Regex pattern for action=regex')
    p_clear.add_argument('--dry-run', action='store_true', help='Print actions only')
    p_clear.add_argument('--yes', action='store_true', help='Assume yes for destructive operations')

    # deploy
    p_deploy = sub.add_parser('deploy', help='Insert a Varnish service into a Docker Compose YAML file')
    p_deploy.add_argument('--dc-config', required=True, help='YAML file containing the Varnish service (single service or services mapping)')
    p_deploy.add_argument('--target-dc-config', required=True, help='Target Docker Compose YAML file to modify')
    p_deploy.add_argument('--dry-run', action='store_true', help='Show what would change, do not write')
    p_deploy.add_argument('--yes', action='store_true', help='Assume yes for destructive operations')

    args = parser.parse_args()

    if args.cmd == 'test':
        sites = parse_sites_arg(args.sites)
        action_test(sites)
    elif args.cmd == 'clear':
        sites = parse_sites_arg(args.sites)
        action_clear(sites, args.action, args.url_path, args.pattern, args.dry_run, args.yes)
    elif args.cmd == 'deploy':
        action_deploy(args.dc_config, args.target_dc_config, args.dry_run, args.yes)


if __name__ == '__main__':
    main()
