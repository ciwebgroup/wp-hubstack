"""Server data models."""

from enum import Enum
from typing import List

from pydantic import BaseModel, Field, field_validator


class ServerStatus(str, Enum):
    """Server capacity status."""

    UNDER_CAPACITY = "under_capacity"
    OPTIMAL = "optimal"
    OVER_CAPACITY = "over_capacity"
    CRITICAL = "critical"


class ServerSpecs(BaseModel):
    """Server hardware specifications."""

    cpu_cores: int = Field(gt=0, description="Number of CPU cores")
    ram_gb: int = Field(gt=0, description="RAM in gigabytes")
    disk_gb: int = Field(gt=0, description="Disk space in gigabytes")


class ServerCapacity(BaseModel):
    """Server capacity information."""

    current_sites: int = Field(ge=0, description="Current number of sites")
    recommended_max: int = Field(gt=0, description="Recommended maximum sites")
    status: ServerStatus = Field(description="Capacity status")

    @field_validator("current_sites")
    @classmethod
    def validate_current_sites(cls, v: int, info: any) -> int:
        """Validate current sites count."""
        if v < 0:
            raise ValueError("Current sites cannot be negative")
        return v

    def utilization_percent(self) -> float:
        """Calculate capacity utilization percentage."""
        if self.recommended_max == 0:
            return 0.0
        return (self.current_sites / self.recommended_max) * 100.0

    def is_over_capacity(self) -> bool:
        """Check if server is over capacity."""
        return self.status in (ServerStatus.OVER_CAPACITY, ServerStatus.CRITICAL)


class Server(BaseModel):
    """Server model."""

    hostname: str = Field(min_length=1, description="Server hostname")
    specs: ServerSpecs = Field(description="Hardware specifications")
    sites: List[str] = Field(default_factory=list, description="List of site domains")
    capacity: ServerCapacity = Field(description="Capacity information")
    ssh_user: str = Field(default="deploy", description="SSH username")
    ssh_port: int = Field(default=22, ge=1, le=65535, description="SSH port")

    @field_validator("hostname")
    @classmethod
    def validate_hostname(cls, v: str) -> str:
        """Validate hostname format."""
        if not v or v.isspace():
            raise ValueError("Hostname cannot be empty")
        return v.lower().strip()

    def add_site(self, domain: str) -> None:
        """Add a site to this server."""
        if domain not in self.sites:
            self.sites.append(domain)
            self.capacity.current_sites = len(self.sites)

    def remove_site(self, domain: str) -> None:
        """Remove a site from this server."""
        if domain in self.sites:
            self.sites.remove(domain)
            self.capacity.current_sites = len(self.sites)

    def update_capacity_status(self) -> None:
        """Update capacity status based on current site count."""
        utilization = self.capacity.utilization_percent()

        if utilization >= 125:
            self.capacity.status = ServerStatus.CRITICAL
        elif utilization > 100:
            self.capacity.status = ServerStatus.OVER_CAPACITY
        elif utilization >= 80:
            self.capacity.status = ServerStatus.OPTIMAL
        else:
            self.capacity.status = ServerStatus.UNDER_CAPACITY

    class Config:
        """Pydantic configuration."""

        use_enum_values = False
