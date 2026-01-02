"""Tier classification commands."""

from typing import Optional

import click
from rich.console import Console
from rich.table import Table

from ..models import Tier
from ..services.classifier import ClassifierService
from ..services.inventory import InventoryService
from ..utils.config import Config

console = Console()


@click.group()
def classify() -> None:
    """Classify sites into performance tiers."""
    pass


@classify.command()
@click.option(
    "--overwrite",
    is_flag=True,
    help="Overwrite existing tier assignments",
)
@click.option(
    "--tier1-threshold",
    type=int,
    help="Minimum daily visitors for Tier 1 (overrides config)",
)
@click.option(
    "--tier2-threshold",
    type=int,
    help="Minimum daily visitors for Tier 2 (overrides config)",
)
@click.pass_context
def auto(
    ctx: click.Context,
    overwrite: bool,
    tier1_threshold: Optional[int],
    tier2_threshold: Optional[int],
) -> None:
    """Auto-classify all sites based on traffic thresholds."""
    config: Config = ctx.obj["config"]

    # Use provided thresholds or fall back to config
    t1_threshold = tier1_threshold or config.tier1_min_visitors
    t2_threshold = tier2_threshold or config.tier2_min_visitors

    # Load inventory
    inventory = InventoryService(config.data_dir)
    inventory.load_inventory()

    if not inventory.sites:
        console.print("[yellow]No sites in inventory. Import sites first.[/yellow]")
        return

    # Create classifier
    classifier = ClassifierService(inventory, t1_threshold, t2_threshold)

    console.print(f"[cyan]Classifying sites...[/cyan]")
    console.print(f"  Tier 1 threshold: {t1_threshold:,} visitors/day")
    console.print(f"  Tier 2 threshold: {t2_threshold:,} visitors/day")
    console.print(f"  Overwrite existing: {overwrite}\n")

    # Classify all sites
    counts = classifier.classify_all(overwrite=overwrite)

    # Save updated inventory
    inventory.save_inventory()

    # Show results
    console.print(f"[green]✓ Classification complete[/green]")
    console.print(f"  Classified: {counts['classified']}")
    console.print(f"  Skipped: {counts['skipped']}")
    console.print(f"  Tier 1: {counts['tier1']}")
    console.print(f"  Tier 2: {counts['tier2']}")
    console.print(f"  Tier 3: {counts['tier3']}")


@classify.command()
@click.argument("domain")
@click.argument("tier", type=click.IntRange(1, 3))
@click.pass_context
def set(ctx: click.Context, domain: str, tier: int) -> None:
    """Manually set tier for a specific site."""
    config: Config = ctx.obj["config"]

    # Load inventory
    inventory = InventoryService(config.data_dir)
    inventory.load_inventory()

    # Create classifier
    classifier = ClassifierService(
        inventory, config.tier1_min_visitors, config.tier2_min_visitors
    )

    try:
        tier_enum = Tier(tier)
        classifier.set_tier(domain, tier_enum)
        inventory.save_inventory()

        console.print(f"[green]✓ Set {domain} to Tier {tier}[/green]")
    except ValueError as e:
        console.print(f"[red]✗ Error: {e}[/red]")
        raise click.Abort()


@classify.command()
@click.option(
    "--format",
    "output_format",
    type=click.Choice(["table", "json"], case_sensitive=False),
    default="table",
    help="Output format",
)
@click.pass_context
def review(ctx: click.Context, output_format: str) -> None:
    """Review current tier classifications."""
    config: Config = ctx.obj["config"]

    # Load inventory
    inventory = InventoryService(config.data_dir)
    inventory.load_inventory()

    # Create classifier
    classifier = ClassifierService(
        inventory, config.tier1_min_visitors, config.tier2_min_visitors
    )

    summary = classifier.get_classification_summary()

    if output_format == "json":
        import json

        console.print(json.dumps(summary, indent=2))
    else:
        console.print("\n[bold cyan]Tier Classification Summary[/bold cyan]\n")
        console.print(f"[bold]Total Sites:[/bold] {summary['total_sites']}")
        console.print(f"  Tier 1 (High): {summary['tier1_sites']}")
        console.print(f"  Tier 2 (Medium): {summary['tier2_sites']}")
        console.print(f"  Tier 3 (Low): {summary['tier3_sites']}")
        console.print(f"  Unassigned: {summary['unassigned_sites']}")
        console.print(f"\n[bold]Classification Progress:[/bold] {summary['classified_percent']}%")

        if summary["servers_with_capacity_issues"] > 0:
            console.print(
                f"\n[yellow]⚠ {summary['servers_with_capacity_issues']} servers have capacity issues[/yellow]"
            )


@classify.command()
@click.option("--server", "-s", help="Check specific server")
@click.pass_context
def validate(ctx: click.Context, server: Optional[str]) -> None:
    """Validate tier assignments against server capacity."""
    config: Config = ctx.obj["config"]

    # Load inventory
    inventory = InventoryService(config.data_dir)
    inventory.load_inventory()

    # Create classifier
    classifier = ClassifierService(
        inventory, config.tier1_min_visitors, config.tier2_min_visitors
    )

    # Get servers to validate
    if server:
        server_obj = inventory.get_server(server)
        if not server_obj:
            console.print(f"[red]✗ Server not found: {server}[/red]")
            raise click.Abort()
        servers = [server_obj]
    else:
        servers = inventory.list_servers()

    # Create validation table
    table = Table(title="Server Capacity Validation")
    table.add_column("Server", style="cyan")
    table.add_column("T1", style="red")
    table.add_column("T2", style="yellow")
    table.add_column("T3", style="green")
    table.add_column("Est. RAM", style="magenta")
    table.add_column("Avail. RAM", style="blue")
    table.add_column("Util %", style="white")
    table.add_column("Status", style="bold")

    issues_found = 0

    for srv in sorted(servers, key=lambda s: s.hostname):
        validation = classifier.validate_server_capacity(srv)

        status_color = "green" if validation["is_valid"] else "red"
        status_text = "✓ OK" if validation["is_valid"] else "✗ OVER"

        if not validation["is_valid"]:
            issues_found += 1

        table.add_row(
            validation["hostname"],
            str(validation["tier1_sites"]),
            str(validation["tier2_sites"]),
            str(validation["tier3_sites"]),
            f"{validation['estimated_ram_gb']:.1f}GB",
            f"{validation['available_ram_gb']:.1f}GB",
            f"{validation['utilization_percent']:.0f}%",
            f"[{status_color}]{status_text}[/{status_color}]",
        )

    console.print(table)

    if issues_found > 0:
        console.print(
            f"\n[yellow]⚠ {issues_found} servers exceed capacity. Consider migration.[/yellow]"
        )
    else:
        console.print(f"\n[green]✓ All servers within capacity[/green]")


@classify.command()
@click.pass_context
def recommend(ctx: click.Context) -> None:
    """Show tier assignment recommendations based on traffic."""
    config: Config = ctx.obj["config"]

    # Load inventory
    inventory = InventoryService(config.data_dir)
    inventory.load_inventory()

    # Create classifier
    classifier = ClassifierService(
        inventory, config.tier1_min_visitors, config.tier2_min_visitors
    )

    recommendations = classifier.get_recommendations()

    if not recommendations:
        console.print("[green]✓ No tier changes recommended[/green]")
        return

    table = Table(title=f"Tier Recommendations ({len(recommendations)} sites)")
    table.add_column("Domain", style="cyan")
    table.add_column("Current", style="yellow")
    table.add_column("Recommended", style="green")
    table.add_column("Visitors/Day", style="magenta")
    table.add_column("Reason", style="white")

    for rec in sorted(recommendations, key=lambda r: r["daily_visitors"], reverse=True):
        table.add_row(
            rec["domain"],
            f"Tier {rec['current_tier']}",
            f"Tier {rec['recommended_tier']}",
            f"{rec['daily_visitors']:,}",
            rec["reason"],
        )

    console.print(table)
    console.print(
        f"\n[cyan]Tip: Use 'classify set <domain> <tier>' to apply recommendations[/cyan]"
    )
