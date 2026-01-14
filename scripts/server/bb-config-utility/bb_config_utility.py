#!/usr/bin/env python3
"""bb_config_utility - apply Traefik site-scoped header middleware for Beaver Builder

Behavior:
- Discover Traefik working dir via docker inspect <container>
- Ensure <workdir>/dynamic exists
- Discover site containers (default: containers whose name start with 'wp_')
- For each site container, create two file-provider middlewares under Traefik dynamic:
  - allow-frame-<site>.yml (minimal headers to set X-Frame-Options)
  - security-headers-<site>.yml (copy of global security but with frameDeny:false)
- Update site docker-compose.yml service labels to reference the site-scoped middleware

This tool uses subprocess + docker inspect and PyYAML for safe edits.
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Dict, List, Optional

import yaml


def run(cmd: List[str]) -> str:
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"Command {cmd!r} failed: {proc.stderr.strip()}")
    return proc.stdout


def inspect_container(container_name: str) -> Dict:
    out = run(["docker", "inspect", container_name])
    data = json.loads(out)
    if not data:
        raise RuntimeError(f"inspect returned empty for {container_name}")
    return data[0]


def get_compose_workdir_from_inspect(container_name: str) -> Optional[str]:
    info = inspect_container(container_name)
    labels = info.get("Config", {}).get("Labels", {}) or {}
    # Common label used in this environment
    key = "com.docker.compose.project.working_dir"
    if key in labels:
        return labels[key]
    # fallback: try project directory label
    for candidate in ["com.docker.compose.project.working_dir", "com.docker.compose.project.working_dir"]:
        if candidate in labels:
            return labels[candidate]
    return None


def find_site_containers() -> List[str]:
    # List containers, filter names starting with wp_
    out = run(["docker", "ps", "--format", "{{.Names}}"])
    names = [n.strip() for n in out.splitlines() if n.strip()]
    return [n for n in names if n.startswith("wp_")]


def ensure_dir(path: Path, dry_run: bool):
    if path.exists():
        return
    if dry_run:
        print(f"[dry-run] Would create directory: {path}")
    else:
        print(f"Creating directory: {path}")
        path.mkdir(parents=True, exist_ok=True)


def write_yaml_file(path: Path, data: Dict, dry_run: bool):
    if dry_run:
        print(f"[dry-run] Would write {path} with content:\n{yaml.safe_dump(data)}")
    else:
        print(f"Writing {path}")
        with open(path, "w", encoding="utf-8") as fh:
            yaml.safe_dump(data, fh, sort_keys=False)


def patch_compose_yaml(compose_path: Path, service_container_name: str, site_name: str, dry_run: bool):
    # Load compose
    with open(compose_path, "r", encoding="utf-8") as fh:
        orig = yaml.safe_load(fh)
    if not orig:
        raise RuntimeError(f"Empty or invalid compose at {compose_path}")
    services = orig.get("services") or {}
    target_service = None
    target_service_key = None
    for key, svc in services.items():
        c_name = svc.get("container_name")
        if c_name == service_container_name or key == service_container_name:
            target_service = svc
            target_service_key = key
            break
    if not target_service:
        # fallback: try service keys starting with site_name
        for key, svc in services.items():
            if key.startswith(site_name):
                target_service = svc
                target_service_key = key
                break
    if not target_service:
        raise RuntimeError(f"Could not find service for container {service_container_name} in {compose_path}")

    labels = target_service.setdefault("labels", [])
    # labels may be dict or list; normalize to list of strings
    if isinstance(labels, dict):
        # convert dict to list 'key=value'
        new_labels = [f"{k}={v}" for k, v in labels.items()]
    else:
        new_labels = list(labels)

    # update router middleware label
    # find router label
    router_label_prefix = f"traefik.http.routers.{target_service_key}.middlewares="
    existing_router_idx = None
    for i, lbl in enumerate(new_labels):
        if isinstance(lbl, str) and lbl.startswith(router_label_prefix):
            existing_router_idx = i
            break
    new_router_value = None
    if existing_router_idx is not None:
        left, right = new_labels[existing_router_idx].split("=", 1)
        parts = [p.strip() for p in right.split(",") if p.strip()]
        # ensure our site middlewares are present
        site_security = f"security-headers-{site_name}@file"
        site_allow = f"allow-frame-{site_name}-docker@docker"
        if site_security not in parts:
            parts.append(site_security)
        if site_allow not in parts:
            parts.append(site_allow)
        new_router_value = router_label_prefix + ",".join(parts)
        new_labels[existing_router_idx] = new_router_value
    else:
        # add a router label (if none existed)
        site_security = f"security-headers-{site_name}@file"
        site_allow = f"allow-frame-{site_name}-docker@docker"
        new_router_value = router_label_prefix + f"wordpress-security@file,{site_security},{site_allow}"
        new_labels.append(new_router_value)

    # Add docker-scoped allow-frame middleware labels
    md_base = f"traefik.http.middlewares.allow-frame-{site_name}-docker"
    add_direct = [
        f"{md_base}.headers.frameDeny=false",
        f"{md_base}.headers.customResponseHeaders.X-Frame-Options=SAMEORIGIN",
        f"{md_base}.headers.customResponseHeaders.Content-Security-Policy=frame-ancestors 'self'",
    ]
    for entry in add_direct:
        if entry not in new_labels:
            new_labels.append(entry)

    # Write back
    if isinstance(labels, dict):
        # convert back to dict if originally dict - keep simple: replace labels key as list
        orig["services"][target_service_key]["labels"] = new_labels
    else:
        orig["services"][target_service_key]["labels"] = new_labels

    if dry_run:
        print(f"[dry-run] Would update {compose_path} -> service {target_service_key} labels:\n{yaml.safe_dump(orig['services'][target_service_key])}")
    else:
        print(f"Updating compose file: {compose_path}")
        with open(compose_path, "w", encoding="utf-8") as fh:
            yaml.safe_dump(orig, fh, sort_keys=False)


def main():
    parser = argparse.ArgumentParser(description="Apply site-scoped Traefik header middleware for Beaver Builder")
    parser.add_argument("--traefik-container", help="Traefik container name (used to discover working dir)")
    parser.add_argument("--traefik-config", help="Override: path to traefik working directory (skips container inspect)")
    parser.add_argument("--site-containers", help="Comma-separated site container names to operate on (default: auto detect wp_*)")
    parser.add_argument("--include", help="Comma-separated names to include (filter)")
    parser.add_argument("--exclude", help="Comma-separated names to exclude")
    parser.add_argument("--dry-run", action="store_true", help="Show planned changes, don't write")

    args = parser.parse_args()

    dry_run = args.dry_run

    if args.traefik_config:
        traefik_workdir = Path(args.traefik_config).resolve()
    else:
        if not args.traefik_container:
            print("Either --traefik-container or --traefik-config must be provided", file=sys.stderr)
            sys.exit(2)
        wd = get_compose_workdir_from_inspect(args.traefik_container)
        if not wd:
            print(f"Could not discover working dir from container {args.traefik_container}", file=sys.stderr)
            sys.exit(1)
        traefik_workdir = Path(wd).resolve()

    print(f"Traefik working dir: {traefik_workdir}")
    dynamic_dir = traefik_workdir / "dynamic"
    ensure_dir(dynamic_dir, dry_run)

    if args.site_containers:
        sites = [s.strip() for s in args.site_containers.split(",") if s.strip()]
    else:
        sites = find_site_containers()

    include = [s.strip() for s in (args.include or "").split(",") if s.strip()]
    exclude = [s.strip() for s in (args.exclude or "").split(",") if s.strip()]

    if include:
        sites = [s for s in sites if s in include]
    if exclude:
        sites = [s for s in sites if s not in exclude]

    if not sites:
        print("No site containers found after filtering; nothing to do.")
        return

    for container in sites:
        # Derive site_name from container: e.g., wp_stoneheatair -> stoneheatair
        site_name = container.replace("wp_", "") if container.startswith("wp_") else container
        print(f"Processing site container: {container} -> site_name: {site_name}")
        try:
            site_wd = get_compose_workdir_from_inspect(container)
        except Exception as exc:
            print(f"Warning: could not inspect container {container}: {exc}")
            site_wd = None
        if not site_wd:
            print(f"Skipping {container}: cannot determine compose working dir")
            continue
        site_compose = Path(site_wd) / "docker-compose.yml"
        if not site_compose.exists():
            print(f"Skipping {container}: compose file not found at {site_compose}")
            continue

        # Create allow-frame file
        allow_frame = {
            "http": {
                "middlewares": {
                    f"allow-frame-{site_name}": {
                        "headers": {
                            "customResponseHeaders": {
                                "X-Frame-Options": "SAMEORIGIN",
                                "Content-Security-Policy": "frame-ancestors 'self'",
                            }
                        }
                    }
                }
            }
        }
        allow_path = dynamic_dir / f"allow-frame-{site_name}.yml"
        write_yaml_file(allow_path, allow_frame, dry_run)

        # Create security-headers site-scoped copy
        security = {
            "http": {
                "middlewares": {
                    f"security-headers-{site_name}": {
                        "headers": {
                            "frameDeny": False,
                            "sslRedirect": True,
                            "browserXssFilter": True,
                            "contentTypeNosniff": True,
                            "forceSTSHeader": True,
                            "stsSeconds": 31536000,
                            "stsIncludeSubdomains": True,
                            "stsPreload": True,
                            "referrerPolicy": "strict-origin-when-cross-origin",
                            "customRequestHeaders": {"X-Forwarded-Proto": "https"},
                            "customResponseHeaders": {"Permissions-Policy": "geolocation=(), microphone=(), camera=()"},
                        }
                    }
                }
            }
        }
        sec_path = dynamic_dir / f"security-headers-{site_name}.yml"
        write_yaml_file(sec_path, security, dry_run)

        # Patch site compose to add labels
        try:
            patch_compose_yaml(Path(site_compose), container, site_name, dry_run)
        except Exception as exc:
            print(f"Failed to patch compose for {container}: {exc}")

    print("Done. If not --dry-run, restart Traefik and recreate site containers to apply changes.")


if __name__ == "__main__":
    main()
