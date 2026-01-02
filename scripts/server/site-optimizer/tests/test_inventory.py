"""Test inventory service."""

from pathlib import Path
from tempfile import TemporaryDirectory

import pytest

from src.models import Server, ServerCapacity, ServerSpecs, ServerStatus, Site, Tier
from src.services.inventory import InventoryService


def test_inventory_service_initialization() -> None:
    """Test inventory service initialization."""
    with TemporaryDirectory() as tmpdir:
        service = InventoryService(Path(tmpdir))
        assert len(service.sites) == 0
        assert len(service.servers) == 0


def test_add_site() -> None:
    """Test adding a site to inventory."""
    with TemporaryDirectory() as tmpdir:
        service = InventoryService(Path(tmpdir))

        site = Site(domain="example.com", server="server01.example.com")
        service.sites[site.domain] = site
        service._ensure_server_exists(site.server)

        assert "example.com" in service.sites
        assert "server01.example.com" in service.servers


def test_save_and_load_inventory() -> None:
    """Test saving and loading inventory."""
    with TemporaryDirectory() as tmpdir:
        service = InventoryService(Path(tmpdir))

        # Add test data
        site = Site(
            domain="test.com",
            server="server01.example.com",
            assigned_tier=Tier.MEDIUM,
        )
        service.sites[site.domain] = site
        service._ensure_server_exists(site.server)

        # Save
        service.save_inventory()
        assert service.inventory_file.exists()

        # Load in new service instance
        service2 = InventoryService(Path(tmpdir))
        service2.load_inventory()

        assert "test.com" in service2.sites
        assert service2.sites["test.com"].assigned_tier == Tier.MEDIUM


def test_get_statistics() -> None:
    """Test inventory statistics."""
    with TemporaryDirectory() as tmpdir:
        service = InventoryService(Path(tmpdir))

        # Add test sites
        for i in range(5):
            site = Site(domain=f"site{i}.com", server="server01.example.com")
            service.sites[site.domain] = site

        service._ensure_server_exists("server01.example.com")

        stats = service.get_statistics()
        assert stats["total_sites"] == 5
        assert stats["total_servers"] == 1
