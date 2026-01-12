#!/usr/bin/env bash
set -euo pipefail

# Run mypy for the OIDC module using the repository-level mypy.ini
# This script runs mypy from the repository root so imports resolve correctly.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"

echo "[INFO] Running mypy for OIDC module (root: $ROOT)"
cd "$ROOT"

# Run mypy only against the OIDC script
mypy --config-file "$ROOT/mypy.ini" "scripts/server/oidc/fix_oidc_settings.py"

echo "[INFO] mypy finished"
