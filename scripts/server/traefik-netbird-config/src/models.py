"""Pydantic models for Traefik Docker Compose configuration."""

from pathlib import Path
from typing import Any, Dict, List, Optional

from pydantic import BaseModel, Field


class NetworkConfig(BaseModel):
    """Docker network configuration."""

    name: Optional[str] = None
    driver: Optional[str] = None
    external: Optional[bool] = None


class ServiceEnvironment(BaseModel):
    """Environment variables for a service."""

    variables: Dict[str, str] = Field(default_factory=dict)


class TraefikService(BaseModel):
    """Traefik service configuration in docker-compose."""

    image: str = Field(description="Docker image for Traefik")
    container_name: Optional[str] = None
    restart: Optional[str] = None
    environment: Optional[Dict[str, str]] = None
    command: List[str] = Field(default_factory=list)
    ports: List[str] = Field(default_factory=list)
    volumes: List[str] = Field(default_factory=list)
    networks: List[str] = Field(default_factory=list)
    labels: List[str] = Field(default_factory=list)

    class Config:
        """Pydantic configuration."""

        extra = "allow"  # Allow extra fields we don't model


class DockerComposeConfig(BaseModel):
    """Docker Compose configuration structure."""

    version: Optional[str] = None
    networks: Dict[str, NetworkConfig] = Field(default_factory=dict)
    services: Dict[str, Dict[str, Any]] = Field(default_factory=dict)

    class Config:
        """Pydantic configuration."""

        extra = "allow"


class ConfigAdditions(BaseModel):
    """Configuration additions to apply to Traefik."""

    command: List[str] = Field(default_factory=list, description="Commands to add")
    ports: List[str] = Field(default_factory=list, description="Ports to add")
    volumes: List[str] = Field(default_factory=list, description="Volumes to add")
    labels: List[str] = Field(default_factory=list, description="Labels to add")
    environment: Dict[str, str] = Field(default_factory=dict, description="Environment vars to add")


class IPTablesRule(BaseModel):
    """Single iptables rule configuration."""

    chain: str = Field(description="Chain name (e.g., DOCKER-USER, INPUT)")
    position: Optional[int] = Field(None, description="Position to insert rule (1-indexed)")
    protocol: str = Field(default="tcp", description="Protocol (tcp, udp, etc)")
    dport: int = Field(description="Destination port")
    interface: Optional[str] = Field(None, description="Network interface (e.g., wt0)")
    source: Optional[str] = Field(None, description="Source IP address")
    action: str = Field(description="Rule action (ACCEPT, DROP, REJECT)")

    def to_insert_command(self) -> List[str]:
        """Generate iptables -I command."""
        cmd = ["iptables", "-I", self.chain]
        if self.position:
            cmd.append(str(self.position))
        cmd.extend(["-p", self.protocol, "--dport", str(self.dport)])
        if self.interface:
            cmd.extend(["-i", self.interface])
        if self.source:
            cmd.extend(["-s", self.source])
        cmd.extend(["-j", self.action])
        return cmd

    def to_delete_command(self) -> List[str]:
        """Generate iptables -D command for cleanup."""
        cmd = ["iptables", "-D", self.chain]
        cmd.extend(["-p", self.protocol, "--dport", str(self.dport)])
        if self.interface:
            cmd.extend(["-i", self.interface])
        if self.source:
            cmd.extend(["-s", self.source])
        cmd.extend(["-j", self.action])
        return cmd


class IPTablesConfig(BaseModel):
    """IPTables firewall configuration."""

    rules: List[IPTablesRule] = Field(default_factory=list, description="Rules to apply")
    cleanup_first: bool = Field(True, description="Remove existing rules before applying")
    persist: bool = Field(True, description="Save rules with netfilter-persistent")


class TraefikAdditionsConfig(BaseModel):
    """Root configuration for additions YAML file."""

    traefik: ConfigAdditions = Field(default_factory=ConfigAdditions)
    iptables: Optional[IPTablesConfig] = Field(None, description="IPTables rules to apply")


class BackupInfo(BaseModel):
    """Information about a backup file."""

    path: Path
    timestamp: str
    size_bytes: int
