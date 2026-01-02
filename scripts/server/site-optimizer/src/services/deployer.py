"""Deployment service for applying tier configurations."""

import shutil
import subprocess
from pathlib import Path
from typing import Dict, List, Optional, Set

import yaml

from ..models import Deployment, DeploymentAction, DeploymentStatus, Site, Tier


class DeployerService:
    """Service for deploying tier configurations to sites."""

    def __init__(
        self,
        config_dir: Path,
        search_dir: Path = Path("/var/opt/sites"),
    ):
        """
        Initialize deployer service.

        Args:
            config_dir: Directory containing tier configuration files
            search_dir: Directory to search for site docker-compose files
        """
        self.config_dir = config_dir
        self.search_dir = search_dir

    def find_wordpress_sites(
        self, include_patterns: Optional[List[str]] = None, exclude_patterns: Optional[List[str]] = None
    ) -> List[Path]:
        """
        Find WordPress sites by locating docker-compose.yml files.

        Args:
            include_patterns: Only include sites matching these patterns
            exclude_patterns: Exclude sites matching these patterns

        Returns:
            List of paths to site directories
        """
        sites: List[Path] = []

        # Find all docker-compose.yml files
        for compose_file in self.search_dir.glob("*/docker-compose.yml"):
            site_dir = compose_file.parent
            site_name = site_dir.name

            # Check if it has a WordPress container
            if not self._has_wordpress_container(compose_file):
                continue

            # Apply filters
            if not self._should_process(site_name, str(site_dir), include_patterns, exclude_patterns):
                continue

            sites.append(site_dir)

        return sorted(sites)

    def deploy_to_site(
        self,
        site_dir: Path,
        tier: Tier,
        dry_run: bool = True,
        overwrite: bool = False,
        restart: bool = False,
    ) -> DeploymentAction:
        """
        Deploy tier configuration to a single site.

        Args:
            site_dir: Path to site directory
            tier: Tier to deploy
            dry_run: If True, only preview changes
            overwrite: If True, overwrite existing configuration
            restart: If True, restart containers after deployment

        Returns:
            DeploymentAction with status
        """
        site_name = site_dir.name
        compose_file = site_dir / "docker-compose.yml"

        action = DeploymentAction(
            site_domain=site_name,
            to_tier=tier,
            status=DeploymentStatus.PENDING,
        )

        try:
            # Check if already configured
            if self._is_configured(compose_file) and not overwrite:
                action.status = DeploymentStatus.COMPLETED
                action.error_message = "Already configured (use --overwrite to update)"
                return action

            if dry_run:
                action.status = DeploymentStatus.COMPLETED
                action.error_message = "Dry run - no changes made"
                return action

            # Backup docker-compose.yml
            backup_file = compose_file.with_suffix(".yml.bak")
            if not backup_file.exists():
                shutil.copy2(compose_file, backup_file)

            # Copy tier configuration files
            self._copy_config_files(site_dir, tier)

            # Update docker-compose.yml with volume mounts
            self._add_volume_mounts(compose_file, tier)

            # Restart containers if requested
            if restart:
                self._restart_containers(site_dir)

            action.status = DeploymentStatus.COMPLETED
            return action

        except Exception as e:
            action.status = DeploymentStatus.FAILED
            action.error_message = str(e)
            return action

    def get_tier_config_files(self, tier: Tier) -> Dict[str, Path]:
        """
        Get tier-specific configuration file paths.

        Args:
            tier: Tier number

        Returns:
            Dictionary mapping config type to file path
        """
        tier_suffix = f".tier{tier.value}"

        return {
            "apache": self.config_dir / f"mpm_prefork.conf{tier_suffix}",
            "php_fpm": self.config_dir / f"php-fpm-pool.conf{tier_suffix}",
            "php_limits": self.config_dir / f"php-limits.ini{tier_suffix}",
        }

    def _has_wordpress_container(self, compose_file: Path) -> bool:
        """Check if docker-compose.yml has a WordPress container."""
        try:
            with open(compose_file, "r") as f:
                data = yaml.safe_load(f)

            if not data or "services" not in data:
                return False

            # Check for containers with names starting with 'wp_'
            for service in data["services"].values():
                if isinstance(service, dict):
                    container_name = service.get("container_name", "")
                    if container_name.startswith("wp_"):
                        return True

            return False
        except Exception:
            return False

    def _should_process(
        self,
        site_name: str,
        site_path: str,
        include_patterns: Optional[List[str]],
        exclude_patterns: Optional[List[str]],
    ) -> bool:
        """Check if site should be processed based on filters."""
        # Check exclude patterns first
        if exclude_patterns:
            for pattern in exclude_patterns:
                pattern = pattern.strip()
                if pattern in site_name or pattern in site_path:
                    return False

        # Check include patterns
        if include_patterns:
            for pattern in include_patterns:
                pattern = pattern.strip()
                if pattern in site_name or pattern in site_path:
                    return True
            return False  # No include pattern matched

        return True  # No filters or passed filters

    def _is_configured(self, compose_file: Path) -> bool:
        """Check if site already has configuration applied."""
        try:
            content = compose_file.read_text()
            return "mpm_prefork.conf:/etc/apache2/mods-available/mpm_prefork.conf" in content
        except Exception:
            return False

    def _copy_config_files(self, site_dir: Path, tier: Tier) -> None:
        """Copy tier configuration files to site directory."""
        config_files = self.get_tier_config_files(tier)

        for config_type, source_file in config_files.items():
            if not source_file.exists():
                raise FileNotFoundError(f"Configuration file not found: {source_file}")

            # Determine destination filename (without tier suffix)
            if config_type == "apache":
                dest_name = "mpm_prefork.conf"
            elif config_type == "php_fpm":
                dest_name = "php-fpm-pool.conf"
            else:  # php_limits
                dest_name = "php-limits.ini"

            dest_file = site_dir / dest_name
            shutil.copy2(source_file, dest_file)

    def _add_volume_mounts(self, compose_file: Path, tier: Tier) -> None:
        """Add volume mounts to docker-compose.yml."""
        with open(compose_file, "r") as f:
            data = yaml.safe_load(f)

        if not data or "services" not in data:
            raise ValueError("Invalid docker-compose.yml structure")

        # Find WordPress service
        for service_name, service in data["services"].items():
            if not isinstance(service, dict):
                continue

            container_name = service.get("container_name", "")
            if not container_name.startswith("wp_"):
                continue

            # Ensure volumes list exists
            if "volumes" not in service:
                service["volumes"] = []

            # Define volume mounts
            volume_mounts = [
                "./mpm_prefork.conf:/etc/apache2/mods-available/mpm_prefork.conf",
                "./php-fpm-pool.conf:/usr/local/etc/php-fpm.d/www.conf",
                "./php-limits.ini:/usr/local/etc/php/conf.d/99-limits.ini",
            ]

            # Remove existing config mounts (for overwrite)
            service["volumes"] = [
                v
                for v in service["volumes"]
                if not any(mount.split(":")[1] in str(v) for mount in volume_mounts)
            ]

            # Add new mounts
            service["volumes"].extend(volume_mounts)

        # Write updated docker-compose.yml
        with open(compose_file, "w") as f:
            yaml.dump(data, f, default_flow_style=False, sort_keys=False)

    def _restart_containers(self, site_dir: Path) -> None:
        """Restart Docker containers for a site."""
        try:
            # Run docker compose down
            subprocess.run(
                ["docker", "compose", "down"],
                cwd=site_dir,
                check=True,
                capture_output=True,
                text=True,
            )

            # Run docker compose up -d
            subprocess.run(
                ["docker", "compose", "up", "-d"],
                cwd=site_dir,
                check=True,
                capture_output=True,
                text=True,
            )
        except subprocess.CalledProcessError as e:
            raise RuntimeError(f"Failed to restart containers: {e.stderr}")
