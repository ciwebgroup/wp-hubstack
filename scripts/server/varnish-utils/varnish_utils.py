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


def main():
    parser = argparse.ArgumentParser(description='Varnish utils: test and clear cache')
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

    args = parser.parse_args()

    if args.cmd == 'test':
        sites = parse_sites_arg(args.sites)
        action_test(sites)
    elif args.cmd == 'clear':
        sites = parse_sites_arg(args.sites)
        action_clear(sites, args.action, args.url_path, args.pattern, args.dry_run, args.yes)


if __name__ == '__main__':
    main()
