"""Configuration management."""

import os
from pathlib import Path
from typing import Optional

from dotenv import load_dotenv
from pydantic import BaseModel, Field


class Config(BaseModel):
    """Application configuration."""

    # Google Analytics
    ga_property_id: Optional[str] = Field(None, description="Google Analytics property ID")
    ga_credentials_path: Optional[Path] = Field(None, description="Path to GA credentials JSON")

    # Tier thresholds
    tier1_min_visitors: int = Field(10000, description="Minimum daily visitors for Tier 1")
    tier2_min_visitors: int = Field(1000, description="Minimum daily visitors for Tier 2")

    # Deployment settings
    dry_run: bool = Field(True, description="Dry run mode")
    parallel_deployments: int = Field(5, gt=0, description="Number of parallel deployments")
    ssh_user: str = Field("deploy", description="SSH username")
    ssh_key_path: Optional[Path] = Field(None, description="Path to SSH private key")

    # Paths
    search_dir: Path = Field(Path("/var/opt/sites"), description="Sites search directory")
    config_dir: Path = Field(
        Path("./config"), description="Directory containing tier configuration files"
    )
    apply_fix_script: Path = Field(
        Path("/var/www/ciwebgroup/wp-hubstack/scripts/server/apache-mem-fix/apply_fix.sh"),
        description="Path to apply_fix.sh script",
    )
    data_dir: Path = Field(Path("./data"), description="Data directory")

    # Logging
    log_level: str = Field("INFO", description="Logging level")

    class Config:
        """Pydantic configuration."""

        validate_assignment = True


def load_config() -> Config:
    """Load configuration from environment variables."""
    # Load .env file if it exists
    env_file = Path(".env")
    if env_file.exists():
        load_dotenv(env_file)

    # Build config from environment
    config_dict = {
        "ga_property_id": os.getenv("GA_PROPERTY_ID"),
        "ga_credentials_path": _get_path_env("GA_CREDENTIALS_PATH"),
        "tier1_min_visitors": int(os.getenv("TIER1_MIN_VISITORS", "10000")),
        "tier2_min_visitors": int(os.getenv("TIER2_MIN_VISITORS", "1000")),
        "dry_run": os.getenv("DRY_RUN", "true").lower() == "true",
        "parallel_deployments": int(os.getenv("PARALLEL_DEPLOYMENTS", "5")),
        "ssh_user": os.getenv("SSH_USER", "deploy"),
        "ssh_key_path": _get_path_env("SSH_KEY_PATH"),
        "search_dir": Path(os.getenv("SEARCH_DIR", "/var/opt/sites")),
        "config_dir": Path(os.getenv("CONFIG_DIR", "./config")),
        "apply_fix_script": Path(
            os.getenv(
                "APPLY_FIX_SCRIPT",
                "/var/www/ciwebgroup/wp-hubstack/scripts/server/apache-mem-fix/apply_fix.sh",
            )
        ),
        "data_dir": Path(os.getenv("DATA_DIR", "./data")),
        "log_level": os.getenv("LOG_LEVEL", "INFO"),
    }

    return Config(**config_dict)


def _get_path_env(key: str) -> Optional[Path]:
    """Get path from environment variable."""
    value = os.getenv(key)
    return Path(value) if value else None
