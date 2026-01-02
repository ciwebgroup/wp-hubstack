"""Main CLI entry point."""

import click
from rich.console import Console

from .commands.classify import classify
from .commands.deploy import deploy
from .commands.inventory import inventory
from .utils.config import load_config

console = Console()


@click.group()
@click.version_option(version="0.1.0")
@click.pass_context
def cli(ctx: click.Context) -> None:
    """
    Site Optimizer - Manage WordPress site deployments across multiple servers.

    Analyze traffic, classify sites into tiers, plan migrations, and deploy
    configurations to optimize resource usage across 548 sites on 33 servers.
    """
    # Load configuration
    ctx.ensure_object(dict)
    ctx.obj["config"] = load_config()


# Register command groups
cli.add_command(inventory)
cli.add_command(classify)
cli.add_command(deploy)


@cli.group()
def analyze() -> None:
    """Analyze site traffic and performance."""
    pass


@cli.group()
def classify() -> None:
    """Classify sites into performance tiers."""
    pass


@cli.group()
def plan() -> None:
    """Plan site migrations and capacity optimization."""
    pass


@cli.group()
def deploy() -> None:
    """Deploy configurations to servers."""
    pass


def main() -> None:
    """Main entry point."""
    cli(obj={})


if __name__ == "__main__":
    main()
