"""YAML handling utilities with comment preservation."""

from pathlib import Path
from typing import Any, Dict

from ruamel.yaml import YAML


def get_yaml_handler() -> YAML:
    """Get a YAML handler configured to preserve comments and formatting."""
    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.indent(mapping=2, sequence=2, offset=2)
    yaml.width = 4096  # Prevent line wrapping
    return yaml


def load_yaml(path: Path) -> Dict[str, Any]:
    """
    Load YAML file with comment preservation.

    Args:
        path: Path to YAML file

    Returns:
        Parsed YAML content as dictionary

    Raises:
        FileNotFoundError: If file doesn't exist
        ValueError: If YAML is invalid
    """
    if not path.exists():
        raise FileNotFoundError(f"YAML file not found: {path}")

    yaml = get_yaml_handler()
    try:
        with open(path, "r", encoding="utf-8") as f:
            content = yaml.load(f)
            return dict(content) if content else {}
    except Exception as e:
        raise ValueError(f"Failed to parse YAML file {path}: {e}") from e


def save_yaml(path: Path, content: Dict[str, Any]) -> None:
    """
    Save dictionary to YAML file preserving formatting.

    Args:
        path: Path to save YAML file
        content: Dictionary content to save
    """
    yaml = get_yaml_handler()
    with open(path, "w", encoding="utf-8") as f:
        yaml.dump(content, f)


def load_yaml_raw(path: Path) -> Any:
    """
    Load YAML file returning raw ruamel object for in-place editing.

    This preserves comments when the object is later saved.

    Args:
        path: Path to YAML file

    Returns:
        Raw ruamel.yaml object
    """
    if not path.exists():
        raise FileNotFoundError(f"YAML file not found: {path}")

    yaml = get_yaml_handler()
    with open(path, "r", encoding="utf-8") as f:
        return yaml.load(f)


def save_yaml_raw(path: Path, content: Any) -> None:
    """
    Save raw ruamel.yaml object to file.

    Args:
        path: Path to save YAML file
        content: Raw ruamel.yaml object
    """
    yaml = get_yaml_handler()
    with open(path, "w", encoding="utf-8") as f:
        yaml.dump(content, f)
