"""Tier classification service."""

from typing import Dict, List, Optional

from ..models import Server, Site, Tier, TrafficStats
from .inventory import InventoryService


class ClassifierService:
    """Service for classifying sites into performance tiers."""

    def __init__(self, inventory: InventoryService, tier1_threshold: int, tier2_threshold: int):
        """
        Initialize classifier service.

        Args:
            inventory: Inventory service instance
            tier1_threshold: Minimum daily visitors for Tier 1
            tier2_threshold: Minimum daily visitors for Tier 2
        """
        self.inventory = inventory
        self.tier1_threshold = tier1_threshold
        self.tier2_threshold = tier2_threshold

    def classify_site(self, site: Site) -> Tier:
        """
        Classify a single site based on traffic.

        Args:
            site: Site to classify

        Returns:
            Assigned tier
        """
        if not site.traffic:
            # Default to Tier 3 if no traffic data
            return Tier.LOW

        daily_visitors = site.traffic.daily_visitors

        if daily_visitors >= self.tier1_threshold:
            return Tier.HIGH
        elif daily_visitors >= self.tier2_threshold:
            return Tier.MEDIUM
        else:
            return Tier.LOW

    def classify_all(self, overwrite: bool = False) -> Dict[str, int]:
        """
        Classify all sites in inventory.

        Args:
            overwrite: If True, overwrite existing tier assignments

        Returns:
            Dictionary with classification counts
        """
        counts = {
            "classified": 0,
            "skipped": 0,
            "tier1": 0,
            "tier2": 0,
            "tier3": 0,
        }

        for site in self.inventory.sites.values():
            # Skip if already classified and not overwriting
            if site.assigned_tier is not None and not overwrite:
                counts["skipped"] += 1
                continue

            # Classify site
            tier = self.classify_site(site)
            site.assigned_tier = tier
            counts["classified"] += 1

            # Update tier counts
            if tier == Tier.HIGH:
                counts["tier1"] += 1
            elif tier == Tier.MEDIUM:
                counts["tier2"] += 1
            else:
                counts["tier3"] += 1

        return counts

    def set_tier(self, domain: str, tier: Tier) -> None:
        """
        Manually set tier for a site.

        Args:
            domain: Site domain
            tier: Tier to assign

        Raises:
            ValueError: If site not found
        """
        site = self.inventory.get_site(domain)
        if not site:
            raise ValueError(f"Site not found: {domain}")

        site.assigned_tier = tier

    def validate_server_capacity(self, server: Server) -> Dict[str, any]:
        """
        Validate that server can handle assigned tiers.

        Args:
            server: Server to validate

        Returns:
            Validation result with warnings
        """
        sites = self.inventory.list_sites(server=server.hostname)

        tier_counts = {Tier.HIGH: 0, Tier.MEDIUM: 0, Tier.LOW: 0}
        for site in sites:
            if site.assigned_tier:
                tier_counts[site.assigned_tier] += 1

        # Calculate estimated RAM usage
        # Tier 1: ~4.5GB, Tier 2: ~2.75GB, Tier 3: ~1.25GB
        estimated_ram = (
            tier_counts[Tier.HIGH] * 4.5 + tier_counts[Tier.MEDIUM] * 2.75 + tier_counts[Tier.LOW] * 1.25
        )

        available_ram = server.specs.ram_gb - 5  # Reserve 5GB for system/MySQL

        return {
            "hostname": server.hostname,
            "tier1_sites": tier_counts[Tier.HIGH],
            "tier2_sites": tier_counts[Tier.MEDIUM],
            "tier3_sites": tier_counts[Tier.LOW],
            "estimated_ram_gb": round(estimated_ram, 2),
            "available_ram_gb": available_ram,
            "is_valid": estimated_ram <= available_ram,
            "utilization_percent": round((estimated_ram / available_ram) * 100, 1) if available_ram > 0 else 0,
        }

    def get_classification_summary(self) -> Dict[str, any]:
        """
        Get summary of current tier classifications.

        Returns:
            Classification summary
        """
        total_sites = len(self.inventory.sites)
        tier_counts = {1: 0, 2: 0, 3: 0, "unassigned": 0}

        for site in self.inventory.sites.values():
            if site.assigned_tier:
                tier_counts[site.assigned_tier.value] += 1
            else:
                tier_counts["unassigned"] += 1

        # Calculate server capacity issues
        servers_with_issues = 0
        for server in self.inventory.servers.values():
            validation = self.validate_server_capacity(server)
            if not validation["is_valid"]:
                servers_with_issues += 1

        return {
            "total_sites": total_sites,
            "tier1_sites": tier_counts[1],
            "tier2_sites": tier_counts[2],
            "tier3_sites": tier_counts[3],
            "unassigned_sites": tier_counts["unassigned"],
            "classified_percent": round(
                ((total_sites - tier_counts["unassigned"]) / total_sites * 100) if total_sites > 0 else 0,
                1,
            ),
            "servers_with_capacity_issues": servers_with_issues,
        }

    def get_recommendations(self) -> List[Dict[str, any]]:
        """
        Get tier assignment recommendations based on traffic patterns.

        Returns:
            List of recommendations
        """
        recommendations = []

        for site in self.inventory.sites.values():
            if not site.traffic:
                continue

            current_tier = site.assigned_tier
            recommended_tier = self.classify_site(site)

            # Check if recommendation differs from current assignment
            if current_tier and current_tier != recommended_tier:
                recommendations.append(
                    {
                        "domain": site.domain,
                        "current_tier": current_tier.value,
                        "recommended_tier": recommended_tier.value,
                        "daily_visitors": site.traffic.daily_visitors,
                        "reason": self._get_recommendation_reason(site.traffic.daily_visitors, recommended_tier),
                    }
                )

        return recommendations

    def _get_recommendation_reason(self, daily_visitors: int, tier: Tier) -> str:
        """Get human-readable reason for tier recommendation."""
        if tier == Tier.HIGH:
            return f"High traffic ({daily_visitors:,} visitors/day) warrants Tier 1 resources"
        elif tier == Tier.MEDIUM:
            return f"Medium traffic ({daily_visitors:,} visitors/day) suitable for Tier 2"
        else:
            return f"Low traffic ({daily_visitors:,} visitors/day) can use Tier 3"
