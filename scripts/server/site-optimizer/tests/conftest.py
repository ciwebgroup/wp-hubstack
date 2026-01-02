"""Test configuration."""

import pytest

from src.utils.config import Config


@pytest.fixture
def config() -> Config:
    """Create test configuration."""
    return Config(
        tier1_min_visitors=10000,
        tier2_min_visitors=1000,
        dry_run=True,
        parallel_deployments=5,
    )
