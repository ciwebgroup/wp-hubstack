#!/bin/bash

MAIN_PATH="/var/opt/scripts/wp-update-suite/main.py"

PASSTHRU_ARGS=()

# Optional flag handled by this wrapper (not passed to main.py)
for arg in "$@"; do
    PASSTHRU_ARGS+=("$arg")
done

# If the first arg is 'docker', run via docker compose (uses docker-compose.yml in repository root)
if [ "${PASSTHRU_ARGS[0]:-}" = "docker" ]; then
    # Drop the 'docker' subcommand
    PASSTHRU_ARGS=("${PASSTHRU_ARGS[@]:1}")
    # Prefer 'docker compose' but fall back to 'docker-compose' if needed
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        echo "Running via docker compose..."
        docker compose run --rm wp-updater python3 /app/main.py "${PASSTHRU_ARGS[@]}"
    else
        echo "Running via docker-compose..."
        docker-compose run --rm wp-updater python3 /app/main.py "${PASSTHRU_ARGS[@]}"
    fi

else
    # Run the script locally on the host using Python 3
    if [ ! -f "$MAIN_PATH" ]; then
        echo "Error: main.py not found at $MAIN_PATH"
        exit 1
    fi

    python3 "$MAIN_PATH" "${PASSTHRU_ARGS[@]}" 2>&1
fi