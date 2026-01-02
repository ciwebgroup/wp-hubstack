"""Inventory management service."""

import json
from pathlib import Path
from typing import Dict, List, Optional

import pandas as pd
from pydantic import ValidationError

from ..models import Server, ServerCapacity, ServerSpecs, ServerStatus, Site


class InventoryService:
    """Service for managing site and server inventory."""

    def __init__(self, data_dir: Path) -> None:
        """Initialize inventory service."""
        self.data_dir = data_dir
        self.inventory_file = data_dir / "inventory.json"
        self.sites: Dict[str, Site] = {}
        self.servers: Dict[str, Server] = {}

    def load_inventory(self) -> None:
        """Load inventory from JSON file."""
        if not self.inventory_file.exists():
            return

        with open(self.inventory_file, "r") as f:
            data = json.load(f)

        # Load sites
        for site_data in data.get("sites", []):
            try:
                site = Site(**site_data)
                self.sites[site.domain] = site
            except ValidationError as e:
                print(f"Warning: Invalid site data for {site_data.get('domain')}: {e}")

        # Load servers
        for server_data in data.get("servers", []):
            try:
                server = Server(**server_data)
                self.servers[server.hostname] = server
            except ValidationError as e:
                print(f"Warning: Invalid server data for {server_data.get('hostname')}: {e}")

    def save_inventory(self) -> None:
        """Save inventory to JSON file."""
        self.data_dir.mkdir(parents=True, exist_ok=True)

        data = {
            "sites": [site.model_dump(mode="json") for site in self.sites.values()],
            "servers": [server.model_dump(mode="json") for server in self.servers.values()],
        }

        with open(self.inventory_file, "w") as f:
            json.dump(data, f, indent=2)

    def import_from_csv(self, csv_path: Path) -> tuple[int, int]:
        """
        Import sites from CSV file.

        Expected columns: domain, server, container_name, site_path

        Returns:
            Tuple of (sites_imported, sites_failed)
        """
        df = pd.read_csv(csv_path)
        required_columns = {"domain", "server"}

        if not required_columns.issubset(df.columns):
            missing = required_columns - set(df.columns)
            raise ValueError(f"CSV missing required columns: {missing}")

        imported = 0
        failed = 0

        for _, row in df.iterrows():
            try:
                site = Site(
                    domain=row["domain"],
                    server=row["server"],
                    container_name=row.get("container_name"),
                    site_path=row.get("site_path"),
                )
                self.sites[site.domain] = site

                # Update server inventory
                self._ensure_server_exists(site.server)
                self.servers[site.server].add_site(site.domain)

                imported += 1
            except (ValidationError, KeyError) as e:
                print(f"Warning: Failed to import {row.get('domain')}: {e}")
                failed += 1

        # Update server capacity statuses
        for server in self.servers.values():
            server.update_capacity_status()

        return imported, failed

    def import_from_json(self, json_path: Path) -> tuple[int, int]:
        """
        Import sites from JSON file.

        Returns:
            Tuple of (sites_imported, sites_failed)
        """
        with open(json_path, "r") as f:
            data = json.load(f)

        imported = 0
        failed = 0

        for site_data in data.get("sites", []):
            try:
                site = Site(**site_data)
                self.sites[site.domain] = site

                # Update server inventory
                self._ensure_server_exists(site.server)
                self.servers[site.server].add_site(site.domain)

                imported += 1
            except ValidationError as e:
                print(f"Warning: Failed to import {site_data.get('domain')}: {e}")
                failed += 1

        return imported, failed

    def get_site(self, domain: str) -> Optional[Site]:
        """Get site by domain."""
        return self.sites.get(domain)

    def get_server(self, hostname: str) -> Optional[Server]:
        """Get server by hostname."""
        return self.servers.get(hostname)

    def list_sites(
        self, server: Optional[str] = None, tier: Optional[int] = None
    ) -> List[Site]:
        """
        List sites with optional filters.

        Args:
            server: Filter by server hostname
            tier: Filter by tier

        Returns:
            List of matching sites
        """
        sites = list(self.sites.values())

        if server:
            sites = [s for s in sites if s.server == server]

        if tier is not None:
            sites = [s for s in sites if s.assigned_tier and s.assigned_tier.value == tier]

        return sites

    def list_servers(self, status: Optional[ServerStatus] = None) -> List[Server]:
        """
        List servers with optional status filter.

        Args:
            status: Filter by capacity status

        Returns:
            List of matching servers
        """
        servers = list(self.servers.values())

        if status:
            servers = [s for s in servers if s.capacity.status == status]

        return servers

    def get_statistics(self) -> Dict[str, int]:
        """Get inventory statistics."""
        total_sites = len(self.sites)
        total_servers = len(self.servers)

        tier_counts = {1: 0, 2: 0, 3: 0, "unassigned": 0}
        for site in self.sites.values():
            if site.assigned_tier:
                tier_counts[site.assigned_tier.value] += 1
            else:
                tier_counts["unassigned"] += 1

        status_counts = {
            "under_capacity": 0,
            "optimal": 0,
            "over_capacity": 0,
            "critical": 0,
        }
        for server in self.servers.values():
            status_counts[server.capacity.status.value] += 1

        return {
            "total_sites": total_sites,
            "total_servers": total_servers,
            "tier1_sites": tier_counts[1],
            "tier2_sites": tier_counts[2],
            "tier3_sites": tier_counts[3],
            "unassigned_sites": tier_counts["unassigned"],
            "under_capacity_servers": status_counts["under_capacity"],
            "optimal_servers": status_counts["optimal"],
            "over_capacity_servers": status_counts["over_capacity"],
            "critical_servers": status_counts["critical"],
        }

    def _ensure_server_exists(self, hostname: str) -> None:
        """Ensure server exists in inventory with default values."""
        if hostname not in self.servers:
            # Create server with default specs (8 cores, 16GB RAM)
            self.servers[hostname] = Server(
                hostname=hostname,
                specs=ServerSpecs(cpu_cores=8, ram_gb=16, disk_gb=500),
                sites=[],
                capacity=ServerCapacity(
                    current_sites=0, recommended_max=16, status=ServerStatus.UNDER_CAPACITY
                ),
            )
