"""Test classifier service."""

from pathlib import Path
from tempfile import TemporaryDirectory

import pytest

from src.models import Site, Tier, TrafficStats
from src.services.classifier import ClassifierService
from src.services.inventory import InventoryService


def test_classify_site_tier1() -> None:
    """Test classifying a high-traffic site."""
    with TemporaryDirectory() as tmpdir:
        inventory = InventoryService(Path(tmpdir))
        classifier = ClassifierService(inventory, tier1_threshold=10000, tier2_threshold=1000)

        site = Site(
            domain="bigsite.com",
            server="server01.example.com",
            traffic=TrafficStats(
                daily_visitors=15000, page_views=45000, bounce_rate=0.4, avg_session_duration=180.0
            ),
        )

        tier = classifier.classify_site(site)
        assert tier == Tier.HIGH


def test_classify_site_tier2() -> None:
    """Test classifying a medium-traffic site."""
    with TemporaryDirectory() as tmpdir:
        inventory = InventoryService(Path(tmpdir))
        classifier = ClassifierService(inventory, tier1_threshold=10000, tier2_threshold=1000)

        site = Site(
            domain="mediumsite.com",
            server="server01.example.com",
            traffic=TrafficStats(
                daily_visitors=5000, page_views=15000, bounce_rate=0.5, avg_session_duration=120.0
            ),
        )

        tier = classifier.classify_site(site)
        assert tier == Tier.MEDIUM


def test_classify_site_tier3() -> None:
    """Test classifying a low-traffic site."""
    with TemporaryDirectory() as tmpdir:
        inventory = InventoryService(Path(tmpdir))
        classifier = ClassifierService(inventory, tier1_threshold=10000, tier2_threshold=1000)

        site = Site(
            domain="smallsite.com",
            server="server01.example.com",
            traffic=TrafficStats(
                daily_visitors=500, page_views=1500, bounce_rate=0.6, avg_session_duration=90.0
            ),
        )

        tier = classifier.classify_site(site)
        assert tier == Tier.LOW


def test_classify_site_no_traffic() -> None:
    """Test classifying a site with no traffic data."""
    with TemporaryDirectory() as tmpdir:
        inventory = InventoryService(Path(tmpdir))
        classifier = ClassifierService(inventory, tier1_threshold=10000, tier2_threshold=1000)

        site = Site(domain="newsite.com", server="server01.example.com")

        tier = classifier.classify_site(site)
        assert tier == Tier.LOW  # Default to Tier 3


def test_classify_all() -> None:
    """Test classifying all sites."""
    with TemporaryDirectory() as tmpdir:
        inventory = InventoryService(Path(tmpdir))
        classifier = ClassifierService(inventory, tier1_threshold=10000, tier2_threshold=1000)

        # Add test sites with different traffic levels
        sites_data = [
            ("high1.com", 15000),
            ("high2.com", 12000),
            ("medium1.com", 5000),
            ("medium2.com", 3000),
            ("low1.com", 500),
            ("low2.com", 200),
        ]

        for domain, visitors in sites_data:
            site = Site(
                domain=domain,
                server="server01.example.com",
                traffic=TrafficStats(
                    daily_visitors=visitors,
                    page_views=visitors * 3,
                    bounce_rate=0.5,
                    avg_session_duration=120.0,
                ),
            )
            inventory.sites[domain] = site

        # Classify all
        counts = classifier.classify_all()

        assert counts["classified"] == 6
        assert counts["tier1"] == 2
        assert counts["tier2"] == 2
        assert counts["tier3"] == 2


def test_set_tier_manual() -> None:
    """Test manually setting a tier."""
    with TemporaryDirectory() as tmpdir:
        inventory = InventoryService(Path(tmpdir))
        classifier = ClassifierService(inventory, tier1_threshold=10000, tier2_threshold=1000)

        site = Site(domain="test.com", server="server01.example.com")
        inventory.sites[site.domain] = site

        # Manually set to Tier 1
        classifier.set_tier("test.com", Tier.HIGH)

        assert inventory.sites["test.com"].assigned_tier == Tier.HIGH


def test_set_tier_not_found() -> None:
    """Test setting tier for non-existent site."""
    with TemporaryDirectory() as tmpdir:
        inventory = InventoryService(Path(tmpdir))
        classifier = ClassifierService(inventory, tier1_threshold=10000, tier2_threshold=1000)

        with pytest.raises(ValueError, match="Site not found"):
            classifier.set_tier("nonexistent.com", Tier.HIGH)


def test_get_classification_summary() -> None:
    """Test getting classification summary."""
    with TemporaryDirectory() as tmpdir:
        inventory = InventoryService(Path(tmpdir))
        classifier = ClassifierService(inventory, tier1_threshold=10000, tier2_threshold=1000)

        # Add sites with assigned tiers
        for i in range(3):
            site = Site(domain=f"tier1-{i}.com", server="server01.example.com", assigned_tier=Tier.HIGH)
            inventory.sites[site.domain] = site

        for i in range(5):
            site = Site(domain=f"tier2-{i}.com", server="server01.example.com", assigned_tier=Tier.MEDIUM)
            inventory.sites[site.domain] = site

        for i in range(7):
            site = Site(domain=f"tier3-{i}.com", server="server01.example.com", assigned_tier=Tier.LOW)
            inventory.sites[site.domain] = site

        summary = classifier.get_classification_summary()

        assert summary["total_sites"] == 15
        assert summary["tier1_sites"] == 3
        assert summary["tier2_sites"] == 5
        assert summary["tier3_sites"] == 7
        assert summary["unassigned_sites"] == 0
        assert summary["classified_percent"] == 100.0
