"""CLI interface for Traefik Config Manager."""

from pathlib import Path
from typing import Optional

import click
from rich.console import Console
from rich.panel import Panel
from rich.table import Table

from .manager import TraefikConfigManager

console = Console()


@click.group()
@click.version_option(version="1.0.0")
def main() -> None:
    """Traefik Config Manager - Safely manage Traefik docker-compose configurations."""
    pass


@main.command()
@click.option(
    "--traefik-dir",
    "-d",
    type=click.Path(exists=True, path_type=Path),
    required=True,
    help="Path to Traefik directory containing docker-compose.yml",
)
@click.option(
    "--config",
    "-c",
    type=click.Path(exists=True, path_type=Path),
    required=True,
    help="Path to additions YAML configuration file",
)
@click.option(
    "--dry-run",
    is_flag=True,
    default=False,
    help="Preview changes without applying them",
)
@click.option(
    "--apply-iptables",
    is_flag=True,
    default=False,
    help="Also apply iptables rules from config (requires root)",
)
def add(traefik_dir: Path, config: Path, dry_run: bool, apply_iptables: bool) -> None:
    """Add configuration to Traefik docker-compose.yml."""
    manager = TraefikConfigManager(traefik_dir)

    try:
        manager.validate_directory()
    except FileNotFoundError as e:
        console.print(f"[red]Error:[/red] {e}")
        raise SystemExit(1)

    if dry_run:
        console.print(Panel("[yellow]DRY RUN MODE[/yellow] - No changes will be made"))

    try:
        changes, backup, iptables_results = manager.apply_additions(
            config, dry_run=dry_run, apply_iptables=apply_iptables
        )
    except Exception as e:
        console.print(f"[red]Error applying additions:[/red] {e}")
        raise SystemExit(1)

    # Display compose changes
    if any(changes.values()):
        table = Table(title="Docker Compose Changes")
        table.add_column("Category", style="cyan")
        table.add_column("Items Added", style="green")

        for category, items in changes.items():
            if items:
                for item in items:
                    table.add_row(category, item)

        console.print(table)

        if backup and not dry_run:
            console.print(
                f"\n[green]✓[/green] Backup created: [blue]{backup.path.name}[/blue]"
            )
            console.print("[green]✓[/green] Compose changes applied successfully")
        elif dry_run:
            console.print("\n[yellow]→[/yellow] Dry run complete. No compose changes written.")
    else:
        console.print("[yellow]No new compose items to add[/yellow] - all items already exist")

    # Display iptables results
    if iptables_results:
        console.print("\n")
        ipt_table = Table(title="IPTables Rules")
        ipt_table.add_column("Action", style="cyan")
        ipt_table.add_column("Command", style="green")

        for cmd in iptables_results.get("cleaned", []):
            ipt_table.add_row("Cleaned", cmd)
        for cmd in iptables_results.get("applied", []):
            ipt_table.add_row("Applied", cmd)
        for err in iptables_results.get("errors", []):
            ipt_table.add_row("[red]Error[/red]", err)

        console.print(ipt_table)

        if not dry_run and not iptables_results.get("errors"):
            console.print("[green]✓[/green] IPTables rules applied and persisted")
        elif dry_run:
            console.print("[yellow]→[/yellow] IPTables dry run - no rules applied")



@main.command()
@click.option(
    "--traefik-dir",
    "-d",
    type=click.Path(exists=True, path_type=Path),
    required=True,
    help="Path to Traefik directory containing docker-compose.yml",
)
@click.option(
    "--dry-run",
    is_flag=True,
    default=False,
    help="Preview rollback without executing",
)
def rollback(traefik_dir: Path, dry_run: bool) -> None:
    """Rollback to the latest backup and restart containers."""
    manager = TraefikConfigManager(traefik_dir)

    try:
        manager.validate_directory()
    except FileNotFoundError as e:
        console.print(f"[red]Error:[/red] {e}")
        raise SystemExit(1)

    latest = manager.get_latest_backup()
    if not latest:
        console.print("[red]Error:[/red] No backups found to restore")
        raise SystemExit(1)

    console.print(f"[cyan]Latest backup:[/cyan] {latest.path.name}")
    console.print(f"[cyan]Timestamp:[/cyan] {latest.timestamp}")
    console.print(f"[cyan]Size:[/cyan] {latest.size_bytes} bytes")

    if dry_run:
        console.print("\n[yellow]DRY RUN:[/yellow] Would restore this backup and restart containers")
        return

    console.print("\n[yellow]Rolling back...[/yellow]")
    success, message = manager.rollback()

    if success:
        console.print(f"[green]✓[/green] {message}")
        console.print("[green]✓[/green] Containers restarted successfully")
    else:
        console.print(f"[red]✗[/red] {message}")
        raise SystemExit(1)


@main.command()
@click.option(
    "--traefik-dir",
    "-d",
    type=click.Path(exists=True, path_type=Path),
    required=True,
    help="Path to Traefik directory containing docker-compose.yml",
)
def list_backups(traefik_dir: Path) -> None:
    """List all available backups."""
    manager = TraefikConfigManager(traefik_dir)

    try:
        manager.validate_directory()
    except FileNotFoundError as e:
        console.print(f"[red]Error:[/red] {e}")
        raise SystemExit(1)

    backups = manager.list_backups()

    if not backups:
        console.print("[yellow]No backups found[/yellow]")
        return

    table = Table(title="Available Backups")
    table.add_column("#", style="dim")
    table.add_column("Filename", style="cyan")
    table.add_column("Timestamp", style="green")
    table.add_column("Size", style="blue")

    for i, backup in enumerate(backups, 1):
        table.add_row(
            str(i),
            backup.path.name,
            backup.timestamp,
            f"{backup.size_bytes:,} bytes",
        )

    console.print(table)


@main.command()
@click.option(
    "--traefik-dir",
    "-d",
    type=click.Path(exists=True, path_type=Path),
    required=True,
    help="Path to Traefik directory containing docker-compose.yml",
)
def show(traefik_dir: Path) -> None:
    """Show current Traefik configuration summary."""
    manager = TraefikConfigManager(traefik_dir)

    try:
        manager.validate_directory()
        compose = manager.load_compose()
    except (FileNotFoundError, ValueError) as e:
        console.print(f"[red]Error:[/red] {e}")
        raise SystemExit(1)

    traefik = compose.get("services", {}).get("traefik", {})

    console.print(Panel("[bold]Traefik Configuration Summary[/bold]"))

    # Commands
    commands = traefik.get("command", [])
    console.print(f"\n[cyan]Commands:[/cyan] {len(commands)}")

    # Ports
    ports = traefik.get("ports", [])
    console.print(f"[cyan]Ports:[/cyan] {', '.join(ports) if ports else 'none'}")

    # Volumes
    volumes = traefik.get("volumes", [])
    console.print(f"[cyan]Volumes:[/cyan] {len(volumes)}")

    # Labels
    labels = traefik.get("labels", [])
    console.print(f"[cyan]Labels:[/cyan] {len(labels)}")

    # Networks
    networks = traefik.get("networks", [])
    console.print(f"[cyan]Networks:[/cyan] {', '.join(networks) if networks else 'none'}")


if __name__ == "__main__":
    main()
