"""Deployment tracking models."""

from datetime import datetime
from enum import Enum
from typing import List, Optional

from pydantic import BaseModel, Field

from .site import Tier


class DeploymentStatus(str, Enum):
    """Deployment status."""

    PENDING = "pending"
    IN_PROGRESS = "in_progress"
    COMPLETED = "completed"
    FAILED = "failed"
    ROLLED_BACK = "rolled_back"


class DeploymentAction(BaseModel):
    """Individual deployment action."""

    site_domain: str = Field(description="Site domain")
    from_tier: Optional[Tier] = Field(None, description="Previous tier")
    to_tier: Tier = Field(description="Target tier")
    status: DeploymentStatus = Field(default=DeploymentStatus.PENDING)
    error_message: Optional[str] = Field(None, description="Error message if failed")
    started_at: Optional[datetime] = None
    completed_at: Optional[datetime] = None

    def duration_seconds(self) -> Optional[float]:
        """Calculate deployment duration in seconds."""
        if self.started_at and self.completed_at:
            return (self.completed_at - self.started_at).total_seconds()
        return None

    class Config:
        """Pydantic configuration."""

        json_encoders = {datetime: lambda v: v.isoformat()}
        use_enum_values = False


class Deployment(BaseModel):
    """Deployment tracking model."""

    deployment_id: str = Field(description="Unique deployment identifier")
    server: str = Field(description="Target server hostname")
    actions: List[DeploymentAction] = Field(default_factory=list)
    status: DeploymentStatus = Field(default=DeploymentStatus.PENDING)
    dry_run: bool = Field(default=True, description="Whether this is a dry run")
    created_at: datetime = Field(default_factory=datetime.now)
    started_at: Optional[datetime] = None
    completed_at: Optional[datetime] = None

    def total_sites(self) -> int:
        """Get total number of sites in deployment."""
        return len(self.actions)

    def completed_sites(self) -> int:
        """Get number of completed sites."""
        return sum(1 for action in self.actions if action.status == DeploymentStatus.COMPLETED)

    def failed_sites(self) -> int:
        """Get number of failed sites."""
        return sum(1 for action in self.actions if action.status == DeploymentStatus.FAILED)

    def progress_percent(self) -> float:
        """Calculate deployment progress percentage."""
        if not self.actions:
            return 0.0
        completed = sum(
            1
            for action in self.actions
            if action.status in (DeploymentStatus.COMPLETED, DeploymentStatus.FAILED)
        )
        return (completed / len(self.actions)) * 100.0

    def is_complete(self) -> bool:
        """Check if deployment is complete."""
        return self.status in (
            DeploymentStatus.COMPLETED,
            DeploymentStatus.FAILED,
            DeploymentStatus.ROLLED_BACK,
        )

    class Config:
        """Pydantic configuration."""

        json_encoders = {datetime: lambda v: v.isoformat()}
        use_enum_values = False
