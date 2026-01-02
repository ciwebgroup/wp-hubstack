"""Core manager for Traefik configuration operations."""

import shutil
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple

from rich.console import Console

from .models import BackupInfo, ConfigAdditions, IPTablesConfig, TraefikAdditionsConfig
from .utils import load_yaml, load_yaml_raw, save_yaml_raw

console = Console()


class TraefikConfigManager:
    """Manages Traefik docker-compose.yml configuration."""

    COMPOSE_FILE = "docker-compose.yml"
    BACKUP_PREFIX = "docker-compose.yml.backup"
    TRAEFIK_SERVICE = "traefik"

    def __init__(self, traefik_dir: Path) -> None:
        """
        Initialize the config manager.

        Args:
            traefik_dir: Path to Traefik directory containing docker-compose.yml
        """
        self.traefik_dir = traefik_dir
        self.compose_path = traefik_dir / self.COMPOSE_FILE

    def validate_directory(self) -> None:
        """
        Validate that the Traefik directory exists and contains required files.

        Raises:
            FileNotFoundError: If directory or compose file doesn't exist
        """
        if not self.traefik_dir.exists():
            raise FileNotFoundError(f"Traefik directory not found: {self.traefik_dir}")

        if not self.compose_path.exists():
            raise FileNotFoundError(
                f"docker-compose.yml not found in: {self.traefik_dir}"
            )

    def load_compose(self) -> Dict[str, Any]:
        """
        Load the docker-compose.yml file.

        Returns:
            Parsed compose configuration
        """
        return load_yaml(self.compose_path)

    def load_additions(self, additions_path: Path) -> TraefikAdditionsConfig:
        """
        Load additions configuration from YAML file.

        Args:
            additions_path: Path to additions YAML file

        Returns:
            Parsed additions configuration
        """
        data = load_yaml(additions_path)
        return TraefikAdditionsConfig.model_validate(data)

    def create_backup(self) -> BackupInfo:
        """
        Create a timestamped backup of docker-compose.yml.

        Returns:
            Information about the created backup
        """
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        backup_path = self.traefik_dir / f"{self.BACKUP_PREFIX}.{timestamp}"

        shutil.copy2(self.compose_path, backup_path)

        return BackupInfo(
            path=backup_path,
            timestamp=timestamp,
            size_bytes=backup_path.stat().st_size,
        )

    def list_backups(self) -> List[BackupInfo]:
        """
        List all available backups sorted by timestamp (newest first).

        Returns:
            List of backup information
        """
        backups: List[BackupInfo] = []

        for path in self.traefik_dir.glob(f"{self.BACKUP_PREFIX}.*"):
            parts = path.name.split(".")
            if len(parts) >= 3:
                timestamp = parts[-1]
                backups.append(
                    BackupInfo(
                        path=path,
                        timestamp=timestamp,
                        size_bytes=path.stat().st_size,
                    )
                )

        backups.sort(key=lambda b: b.timestamp, reverse=True)
        return backups

    def get_latest_backup(self) -> Optional[BackupInfo]:
        """Get the most recent backup."""
        backups = self.list_backups()
        return backups[0] if backups else None

    def rollback(self) -> Tuple[bool, str]:
        """
        Restore the latest backup and restart Traefik containers.

        Returns:
            Tuple of (success, message)
        """
        latest = self.get_latest_backup()
        if not latest:
            return False, "No backups found to restore"

        shutil.copy2(latest.path, self.compose_path)

        try:
            subprocess.run(
                ["docker", "compose", "down"],
                cwd=self.traefik_dir,
                check=True,
                capture_output=True,
            )
            subprocess.run(
                ["docker", "compose", "up", "-d"],
                cwd=self.traefik_dir,
                check=True,
                capture_output=True,
            )
            return True, f"Restored from backup: {latest.path.name}"
        except subprocess.CalledProcessError as e:
            return False, f"Failed to restart containers: {e.stderr.decode()}"

    def merge_additions(
        self, additions: ConfigAdditions, dry_run: bool = False
    ) -> Dict[str, List[str]]:
        """
        Merge additions into the docker-compose.yml.

        Args:
            additions: Configuration additions to apply
            dry_run: If True, don't write changes

        Returns:
            Dictionary of changes made (field -> list of added items)
        """
        compose = load_yaml_raw(self.compose_path)

        if "services" not in compose or self.TRAEFIK_SERVICE not in compose["services"]:
            raise ValueError(f"Service '{self.TRAEFIK_SERVICE}' not found in compose file")

        traefik = compose["services"][self.TRAEFIK_SERVICE]
        changes: Dict[str, List[str]] = {
            "command": [],
            "ports": [],
            "volumes": [],
            "labels": [],
            "environment": [],
        }

        # Merge commands
        if additions.command:
            existing: Set[str] = set(traefik.get("command", []))
            for cmd in additions.command:
                if cmd not in existing:
                    if "command" not in traefik:
                        traefik["command"] = []
                    traefik["command"].append(cmd)
                    changes["command"].append(cmd)

        # Merge ports
        if additions.ports:
            existing = set(traefik.get("ports", []))
            for port in additions.ports:
                if port not in existing:
                    if "ports" not in traefik:
                        traefik["ports"] = []
                    traefik["ports"].append(port)
                    changes["ports"].append(port)

        # Merge volumes
        if additions.volumes:
            existing = set(traefik.get("volumes", []))
            for volume in additions.volumes:
                if volume not in existing:
                    if "volumes" not in traefik:
                        traefik["volumes"] = []
                    traefik["volumes"].append(volume)
                    changes["volumes"].append(volume)

        # Merge labels
        if additions.labels:
            existing = set(traefik.get("labels", []))
            for label in additions.labels:
                if label not in existing:
                    if "labels" not in traefik:
                        traefik["labels"] = []
                    traefik["labels"].append(label)
                    changes["labels"].append(label)

        # Merge environment
        if additions.environment:
            if "environment" not in traefik:
                traefik["environment"] = {}
            for key, value in additions.environment.items():
                if key not in traefik["environment"]:
                    traefik["environment"][key] = value
                    changes["environment"].append(f"{key}={value}")

        if not dry_run:
            save_yaml_raw(self.compose_path, compose)

        return changes

    def apply_iptables(
        self, config: IPTablesConfig, dry_run: bool = False
    ) -> Dict[str, List[str]]:
        """
        Apply iptables rules from configuration.

        Args:
            config: IPTables configuration
            dry_run: If True, don't execute commands

        Returns:
            Dictionary with 'cleaned', 'applied', and 'errors' lists
        """
        results: Dict[str, List[str]] = {
            "cleaned": [],
            "applied": [],
            "errors": [],
        }

        # Cleanup existing rules first (in reverse order)
        if config.cleanup_first:
            for rule in reversed(config.rules):
                cmd = rule.to_delete_command()
                cmd_str = " ".join(cmd)
                if dry_run:
                    results["cleaned"].append(cmd_str)
                else:
                    subprocess.run(cmd, capture_output=True)
                    results["cleaned"].append(cmd_str)

        # Apply rules in order
        for rule in config.rules:
            cmd = rule.to_insert_command()
            cmd_str = " ".join(cmd)
            if dry_run:
                results["applied"].append(cmd_str)
            else:
                try:
                    subprocess.run(cmd, check=True, capture_output=True)
                    results["applied"].append(cmd_str)
                except subprocess.CalledProcessError as e:
                    results["errors"].append(f"{cmd_str}: {e.stderr.decode().strip()}")

        # Persist rules
        if config.persist and not dry_run:
            try:
                subprocess.run(
                    ["netfilter-persistent", "save"],
                    check=True,
                    capture_output=True,
                )
            except subprocess.CalledProcessError as e:
                results["errors"].append(
                    f"netfilter-persistent save: {e.stderr.decode().strip()}"
                )
            except FileNotFoundError:
                results["errors"].append(
                    "netfilter-persistent not found - rules not persisted"
                )

        return results

    def copy_dynamic_config(
        self, source_dir: Path, dry_run: bool = False
    ) -> Dict[str, List[str]]:
        """
        Copy dynamic configuration files to traefik/dynamic directory.

        Args:
            source_dir: Source directory containing dynamic config files
            dry_run: If True, don't copy files

        Returns:
            Dictionary with 'copied' files list
        """
        results: Dict[str, List[str]] = {
            "copied": [],
            "errors": [],
        }

        target_dir = self.traefik_dir / "dynamic"

        if not source_dir.exists():
            results["errors"].append(f"Source directory not found: {source_dir}")
            return results

        # Get list of files to copy
        files_to_copy = list(source_dir.glob("*.yml")) + list(source_dir.glob("*.yaml"))

        for src_file in files_to_copy:
            dest_file = target_dir / src_file.name
            if dry_run:
                results["copied"].append(f"{src_file.name} -> {dest_file}")
            else:
                try:
                    target_dir.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(src_file, dest_file)
                    results["copied"].append(f"{src_file.name} -> {dest_file}")
                except Exception as e:
                    results["errors"].append(f"{src_file.name}: {e}")

        return results

    def restart_traefik(self) -> Tuple[bool, str]:
        """
        Restart Traefik using docker compose.

        Returns:
            Tuple of (success, message)
        """
        try:
            subprocess.run(
                ["docker", "compose", "restart", "traefik"],
                cwd=self.traefik_dir,
                check=True,
                capture_output=True,
            )
            return True, "Traefik container restarted"
        except subprocess.CalledProcessError as e:
            return False, f"Failed to restart Traefik: {e.stderr.decode()}"

    def apply_additions(
        self,
        additions_path: Path,
        dry_run: bool = False,
        apply_iptables: bool = False,
        restart: bool = False,
    ) -> Dict[str, Any]:
        """
        Apply additions from a YAML file to docker-compose.yml.

        Args:
            additions_path: Path to additions YAML file
            dry_run: If True, don't write changes
            apply_iptables: If True, also apply iptables rules
            restart: If True, restart Traefik after changes

        Returns:
            Dictionary containing all results
        """
        self.validate_directory()

        config = self.load_additions(additions_path)
        results: Dict[str, Any] = {
            "backup": None,
            "compose_changes": {},
            "dynamic_copy": None,
            "iptables": None,
            "restart": None,
        }

        # Create backup before changes (unless dry run)
        if not dry_run:
            results["backup"] = self.create_backup()

        # Merge compose changes
        results["compose_changes"] = self.merge_additions(config.traefik, dry_run=dry_run)

        # Copy dynamic config if specified
        if config.copy_dynamic:
            source_dir = Path(config.copy_dynamic)
            results["dynamic_copy"] = self.copy_dynamic_config(source_dir, dry_run=dry_run)

        # Apply iptables rules
        if apply_iptables and config.iptables:
            results["iptables"] = self.apply_iptables(config.iptables, dry_run=dry_run)

        # Restart Traefik if requested
        if restart and not dry_run:
            success, msg = self.restart_traefik()
            results["restart"] = {"success": success, "message": msg}

        return results

