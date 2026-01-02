"""Data models for Site Optimizer."""

from datetime import datetime
from enum import IntEnum
from typing import Optional

from pydantic import BaseModel, Field, field_validator


class Tier(IntEnum):
    """Site performance tier classification."""

    HIGH = 1  # High-traffic sites
    MEDIUM = 2  # Medium-traffic sites
    LOW = 3  # Low-traffic sites


class TrafficStats(BaseModel):
    """Traffic statistics for a site."""

    daily_visitors: int = Field(ge=0, description="Average daily visitors")
    page_views: int = Field(ge=0, description="Average daily page views")
    bounce_rate: float = Field(ge=0.0, le=1.0, description="Bounce rate (0-1)")
    avg_session_duration: float = Field(ge=0.0, description="Average session duration in seconds")
    last_updated: datetime = Field(default_factory=datetime.now)

    class Config:
        """Pydantic configuration."""

        json_encoders = {datetime: lambda v: v.isoformat()}


class ResourceConfig(BaseModel):
    """Resource configuration for a site."""

    max_workers: int = Field(gt=0, description="Maximum PHP-FPM workers")
    memory_limit: str = Field(pattern=r"^\d+[MG]$", description="PHP memory limit (e.g., 512M)")
    max_execution_time: int = Field(gt=0, description="PHP max execution time in seconds")
    upload_max_filesize: str = Field(
        pattern=r"^\d+[MG]$", description="Max upload file size (e.g., 128M)"
    )


class Site(BaseModel):
    """WordPress site model."""

    domain: str = Field(min_length=1, description="Site domain name")
    server: str = Field(min_length=1, description="Server hostname")
    current_tier: Optional[Tier] = Field(None, description="Currently deployed tier")
    assigned_tier: Optional[Tier] = Field(None, description="Tier to be deployed")
    traffic: Optional[TrafficStats] = Field(None, description="Traffic statistics")
    resources: Optional[ResourceConfig] = Field(None, description="Resource configuration")
    container_name: Optional[str] = Field(None, description="Docker container name")
    site_path: Optional[str] = Field(None, description="Path to site directory")

    @field_validator("domain")
    @classmethod
    def validate_domain(cls, v: str) -> str:
        """Validate domain format."""
        if not v or v.isspace():
            raise ValueError("Domain cannot be empty")
        return v.lower().strip()

    @field_validator("server")
    @classmethod
    def validate_server(cls, v: str) -> str:
        """Validate server hostname."""
        if not v or v.isspace():
            raise ValueError("Server cannot be empty")
        return v.lower().strip()

    def needs_update(self) -> bool:
        """Check if site needs tier update."""
        if self.current_tier is None or self.assigned_tier is None:
            return False
        return self.current_tier != self.assigned_tier

    class Config:
        """Pydantic configuration."""

        use_enum_values = False
