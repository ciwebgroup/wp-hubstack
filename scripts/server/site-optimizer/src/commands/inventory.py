"""Inventory management commands."""

from pathlib import Path
from typing import Optional

import click
from rich.console import Console
from rich.table import Table

from ..models import ServerStatus
from ..services.inventory import InventoryService
from ..utils.config import Config

console = Console()


@click.group()
def inventory() -> None:
    """Manage site and server inventory."""
    pass


@inventory.command()
@click.option(
    "--file",
    "-f",
    "file_path",
    type=click.Path(exists=True, path_type=Path),
    required=True,
    help="Path to CSV or JSON file",
)
@click.option(
    "--format",
    "file_format",
    type=click.Choice(["csv", "json"], case_sensitive=False),
    help="File format (auto-detected if not specified)",
)
@click.pass_context
def import_sites(ctx: click.Context, file_path: Path, file_format: Optional[str]) -> None:
    """Import sites from CSV or JSON file."""
    config: Config = ctx.obj["config"]
    service = InventoryService(config.data_dir)

    # Load existing inventory
    service.load_inventory()

    # Auto-detect format if not specified
    if not file_format:
        file_format = "csv" if file_path.suffix.lower() == ".csv" else "json"

    console.print(f"[cyan]Importing sites from {file_path}...[/cyan]")

    try:
        if file_format == "csv":
            imported, failed = service.import_from_csv(file_path)
        else:
            imported, failed = service.import_from_json(file_path)

        # Save updated inventory
        service.save_inventory()

        console.print(f"[green]✓ Imported {imported} sites[/green]")
        if failed > 0:
            console.print(f"[yellow]⚠ Failed to import {failed} sites[/yellow]")

        # Show statistics
        stats = service.get_statistics()
        console.print(f"\n[bold]Total sites:[/bold] {stats['total_sites']}")
        console.print(f"[bold]Total servers:[/bold] {stats['total_servers']}")

    except Exception as e:
        console.print(f"[red]✗ Error importing sites: {e}[/red]")
        raise click.Abort()


@inventory.command()
@click.option("--server", "-s", help="Filter by server hostname")
@click.option("--tier", "-t", type=int, help="Filter by tier (1, 2, or 3)")
@click.option(
    "--format",
    "output_format",
    type=click.Choice(["table", "json"], case_sensitive=False),
    default="table",
    help="Output format",
)
@click.pass_context
def list_sites(
    ctx: click.Context, server: Optional[str], tier: Optional[int], output_format: str
) -> None:
    """List all sites in inventory."""
    config: Config = ctx.obj["config"]
    service = InventoryService(config.data_dir)
    service.load_inventory()

    sites = service.list_sites(server=server, tier=tier)

    if not sites:
        console.print("[yellow]No sites found[/yellow]")
        return

    if output_format == "json":
        import json

        data = [site.model_dump(mode="json") for site in sites]
        console.print(json.dumps(data, indent=2))
    else:
        table = Table(title=f"Sites ({len(sites)} total)")
        table.add_column("Domain", style="cyan")
        table.add_column("Server", style="green")
        table.add_column("Current Tier", style="yellow")
        table.add_column("Assigned Tier", style="magenta")
        table.add_column("Container", style="blue")

        for site in sorted(sites, key=lambda s: s.domain):
            table.add_row(
                site.domain,
                site.server,
                str(site.current_tier.value) if site.current_tier else "-",
                str(site.assigned_tier.value) if site.assigned_tier else "-",
                site.container_name or "-",
            )

        console.print(table)


@inventory.command()
@click.option(
    "--status",
    type=click.Choice(["under_capacity", "optimal", "over_capacity", "critical"]),
    help="Filter by capacity status",
)
@click.option(
    "--format",
    "output_format",
    type=click.Choice(["table", "json"], case_sensitive=False),
    default="table",
    help="Output format",
)
@click.pass_context
def list_servers(ctx: click.Context, status: Optional[str], output_format: str) -> None:
    """List all servers in inventory."""
    config: Config = ctx.obj["config"]
    service = InventoryService(config.data_dir)
    service.load_inventory()

    status_enum = ServerStatus(status) if status else None
    servers = service.list_servers(status=status_enum)

    if not servers:
        console.print("[yellow]No servers found[/yellow]")
        return

    if output_format == "json":
        import json

        data = [server.model_dump(mode="json") for server in servers]
        console.print(json.dumps(data, indent=2))
    else:
        table = Table(title=f"Servers ({len(servers)} total)")
        table.add_column("Hostname", style="cyan")
        table.add_column("CPU Cores", style="green")
        table.add_column("RAM (GB)", style="green")
        table.add_column("Sites", style="yellow")
        table.add_column("Recommended Max", style="yellow")
        table.add_column("Utilization", style="magenta")
        table.add_column("Status", style="red")

        for server in sorted(servers, key=lambda s: s.hostname):
            utilization = server.capacity.utilization_percent()
            status_color = {
                ServerStatus.UNDER_CAPACITY: "green",
                ServerStatus.OPTIMAL: "yellow",
                ServerStatus.OVER_CAPACITY: "red",
                ServerStatus.CRITICAL: "bold red",
            }[server.capacity.status]

            table.add_row(
                server.hostname,
                str(server.specs.cpu_cores),
                str(server.specs.ram_gb),
                str(server.capacity.current_sites),
                str(server.capacity.recommended_max),
                f"{utilization:.1f}%",
                f"[{status_color}]{server.capacity.status.value}[/{status_color}]",
            )

        console.print(table)


@inventory.command()
@click.pass_context
def stats(ctx: click.Context) -> None:
    """Show inventory statistics."""
    config: Config = ctx.obj["config"]
    service = InventoryService(config.data_dir)
    service.load_inventory()

    statistics = service.get_statistics()

    console.print("\n[bold cyan]Inventory Statistics[/bold cyan]\n")

    # Sites
    console.print("[bold]Sites:[/bold]")
    console.print(f"  Total: {statistics['total_sites']}")
    console.print(f"  Tier 1: {statistics['tier1_sites']}")
    console.print(f"  Tier 2: {statistics['tier2_sites']}")
    console.print(f"  Tier 3: {statistics['tier3_sites']}")
    console.print(f"  Unassigned: {statistics['unassigned_sites']}")

    # Servers
    console.print(f"\n[bold]Servers:[/bold]")
    console.print(f"  Total: {statistics['total_servers']}")
    console.print(f"  [green]Under Capacity: {statistics['under_capacity_servers']}[/green]")
    console.print(f"  [yellow]Optimal: {statistics['optimal_servers']}[/yellow]")
    console.print(f"  [red]Over Capacity: {statistics['over_capacity_servers']}[/red]")
    console.print(f"  [bold red]Critical: {statistics['critical_servers']}[/bold red]")

    # Calculate average sites per server
    if statistics["total_servers"] > 0:
        avg_sites = statistics["total_sites"] / statistics["total_servers"]
        console.print(f"\n[bold]Average sites per server:[/bold] {avg_sites:.1f}")
