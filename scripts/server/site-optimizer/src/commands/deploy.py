"""Deployment commands."""

from pathlib import Path
from typing import List, Optional

import click
from rich.console import Console
from rich.progress import Progress, SpinnerColumn, TextColumn
from rich.table import Table

from ..models import DeploymentStatus, Tier
from ..services.deployer import DeployerService
from ..services.inventory import InventoryService
from ..utils.config import Config

console = Console()


@click.group()
def deploy() -> None:
    """Deploy tier configurations to sites."""
    pass


@deploy.command()
@click.option("--tier", "-t", type=click.IntRange(1, 3), required=True, help="Tier to deploy (1, 2, or 3)")
@click.option("--include", "include_patterns", help="Only deploy to sites matching pattern (comma-separated)")
@click.option("--exclude", "exclude_patterns", help="Exclude sites matching pattern (comma-separated)")
@click.option("--dry-run", is_flag=True, default=True, help="Preview changes without applying")
@click.option("--no-dry-run", is_flag=True, help="Actually apply changes (disables dry-run)")
@click.option("--overwrite", is_flag=True, help="Overwrite existing configurations")
@click.option("--restart", is_flag=True, help="Restart containers after deployment")
@click.option(
    "--config-dir",
    type=click.Path(exists=True, path_type=Path),
    help="Directory containing tier config files",
)
@click.pass_context
def execute(
    ctx: click.Context,
    tier: int,
    include_patterns: Optional[str],
    exclude_patterns: Optional[str],
    dry_run: bool,
    no_dry_run: bool,
    overwrite: bool,
    restart: bool,
    config_dir: Optional[Path],
) -> None:
    """Execute deployment to sites."""
    config: Config = ctx.obj["config"]

    # Handle dry-run flag
    is_dry_run = dry_run and not no_dry_run

    # Use provided config dir or from config
    conf_dir = config_dir or config.config_dir

    # Parse patterns
    include_list = [p.strip() for p in include_patterns.split(",")] if include_patterns else None
    exclude_list = [p.strip() for p in exclude_patterns.split(",")] if exclude_patterns else None

    # Create deployer
    deployer = DeployerService(config_dir=conf_dir, search_dir=config.search_dir)

    # Show deployment info
    tier_enum = Tier(tier)
    console.print(f"\n[bold cyan]Tier {tier} Deployment[/bold cyan]")
    console.print(f"  Mode: {'[yellow]DRY RUN[/yellow]' if is_dry_run else '[red]LIVE[/red]'}")
    console.print(f"  Overwrite: {overwrite}")
    console.print(f"  Restart: {restart}")
    if include_list:
        console.print(f"  Include: {', '.join(include_list)}")
    if exclude_list:
        console.print(f"  Exclude: {', '.join(exclude_list)}")
    console.print()

    # Find sites
    console.print("[cyan]Finding WordPress sites...[/cyan]")
    sites = deployer.find_wordpress_sites(include_patterns=include_list, exclude_patterns=exclude_list)

    if not sites:
        console.print("[yellow]No sites found matching criteria[/yellow]")
        return

    console.print(f"[green]Found {len(sites)} sites[/green]\n")

    # Deploy to each site
    results = []

    with Progress(
        SpinnerColumn(),
        TextColumn("[progress.description]{task.description}"),
        console=console,
    ) as progress:
        task = progress.add_task(f"Deploying to {len(sites)} sites...", total=len(sites))

        for site_dir in sites:
            progress.update(task, description=f"Deploying to {site_dir.name}...")

            action = deployer.deploy_to_site(
                site_dir=site_dir,
                tier=tier_enum,
                dry_run=is_dry_run,
                overwrite=overwrite,
                restart=restart,
            )

            results.append((site_dir.name, action))
            progress.advance(task)

    # Show results
    table = Table(title=f"Deployment Results ({len(results)} sites)")
    table.add_column("Site", style="cyan")
    table.add_column("Status", style="bold")
    table.add_column("Message", style="white")

    success_count = 0
    failed_count = 0
    skipped_count = 0

    for site_name, action in results:
        if action.status == DeploymentStatus.COMPLETED:
            if action.error_message and "Already configured" in action.error_message:
                status_color = "yellow"
                status_text = "SKIPPED"
                skipped_count += 1
            elif action.error_message and "Dry run" in action.error_message:
                status_color = "blue"
                status_text = "DRY RUN"
                success_count += 1
            else:
                status_color = "green"
                status_text = "SUCCESS"
                success_count += 1
        else:
            status_color = "red"
            status_text = "FAILED"
            failed_count += 1

        table.add_row(
            site_name,
            f"[{status_color}]{status_text}[/{status_color}]",
            action.error_message or "Configuration applied",
        )

    console.print(table)

    # Summary
    console.print(f"\n[bold]Summary:[/bold]")
    console.print(f"  Success: {success_count}")
    console.print(f"  Skipped: {skipped_count}")
    console.print(f"  Failed: {failed_count}")

    if is_dry_run:
        console.print(f"\n[yellow]This was a dry run. Use --no-dry-run to apply changes.[/yellow]")


@deploy.command()
@click.option("--include", "include_patterns", help="Only preview sites matching pattern (comma-separated)")
@click.option("--exclude", "exclude_patterns", help="Exclude sites matching pattern (comma-separated)")
@click.option(
    "--config-dir",
    type=click.Path(exists=True, path_type=Path),
    help="Directory containing tier config files",
)
@click.pass_context
def preview(
    ctx: click.Context,
    include_patterns: Optional[str],
    exclude_patterns: Optional[str],
    config_dir: Optional[Path],
) -> None:
    """Preview sites that would be affected by deployment."""
    config: Config = ctx.obj["config"]

    # Use provided config dir or from config
    conf_dir = config_dir or config.config_dir

    # Parse patterns
    include_list = [p.strip() for p in include_patterns.split(",")] if include_patterns else None
    exclude_list = [p.strip() for p in exclude_patterns.split(",")] if exclude_patterns else None

    # Create deployer
    deployer = DeployerService(config_dir=conf_dir, search_dir=config.search_dir)

    # Find sites
    console.print("[cyan]Finding WordPress sites...[/cyan]")
    sites = deployer.find_wordpress_sites(include_patterns=include_list, exclude_patterns=exclude_list)

    if not sites:
        console.print("[yellow]No sites found matching criteria[/yellow]")
        return

    # Show sites
    table = Table(title=f"Sites ({len(sites)} total)")
    table.add_column("Site Name", style="cyan")
    table.add_column("Path", style="white")
    table.add_column("Configured", style="yellow")

    for site_dir in sorted(sites):
        compose_file = site_dir / "docker-compose.yml"
        is_configured = deployer._is_configured(compose_file)

        table.add_row(
            site_dir.name,
            str(site_dir),
            "[green]Yes[/green]" if is_configured else "[red]No[/red]",
        )

    console.print(table)


@deploy.command()
@click.pass_context
def status(ctx: click.Context) -> None:
    """Show deployment status across all sites."""
    config: Config = ctx.obj["config"]

    # Load inventory
    inventory = InventoryService(config.data_dir)
    inventory.load_inventory()

    # Create deployer
    deployer = DeployerService(config_dir=config.config_dir, search_dir=config.search_dir)

    # Get statistics
    total_sites = len(inventory.sites)
    configured_count = 0
    tier_counts = {1: 0, 2: 0, 3: 0, "unassigned": 0}

    for site in inventory.sites.values():
        # Check if site directory exists and is configured
        site_dir = config.search_dir / site.domain
        if site_dir.exists():
            compose_file = site_dir / "docker-compose.yml"
            if compose_file.exists() and deployer._is_configured(compose_file):
                configured_count += 1

        # Count tier assignments
        if site.assigned_tier:
            tier_counts[site.assigned_tier.value] += 1
        else:
            tier_counts["unassigned"] += 1

    # Display status
    console.print("\n[bold cyan]Deployment Status[/bold cyan]\n")
    console.print(f"[bold]Total Sites:[/bold] {total_sites}")
    console.print(f"  Configured: {configured_count}")
    console.print(f"  Not Configured: {total_sites - configured_count}")
    console.print(f"\n[bold]Tier Assignments:[/bold]")
    console.print(f"  Tier 1: {tier_counts[1]}")
    console.print(f"  Tier 2: {tier_counts[2]}")
    console.print(f"  Tier 3: {tier_counts[3]}")
    console.print(f"  Unassigned: {tier_counts['unassigned']}")

    if tier_counts["unassigned"] > 0:
        console.print(
            f"\n[yellow]⚠ {tier_counts['unassigned']} sites need tier classification[/yellow]"
        )
