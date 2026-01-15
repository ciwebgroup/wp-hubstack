#!/bin/bash

set -eaou pipefail

# Flag to control whether to display full outputs
DISPLAY_OUTPUTS=false

# Parse flags
for arg in "$@"; do
  case "$arg" in
    --display-outputs)
      DISPLAY_OUTPUTS=true
      ;;
  esac
done

HOSTNAME=$(hostname)

ROUTERS_OUTPUT=$(curl "$HOSTNAME.netbird.selfhosted:8082/api/http/routers")

# IF ROUTERS_OUTPUT is empty, the curl command failed or Traefik is not responding
if [ -z "$ROUTERS_OUTPUT" ]; then
  echo "Error: Unable to reach Traefik API at $HOSTNAME.netbird.selfhosted:8082"
  exit 1
else
  echo "Traefik API is reachable."
  if [ "$DISPLAY_OUTPUTS" = true ]; then
    echo "Routers output:"
    echo "$ROUTERS_OUTPUT"
  fi
fi

echo "Testing access to /metrics endpoint:"

METRICS_OUTPUT=$(curl "$HOSTNAME.netbird.selfhosted:8082/metrics")

# IF METRICS_OUTPUT is empty, the curl command failed or the endpoint is not accessible

if [ -z "$METRICS_OUTPUT" ]; then
  echo "Error: Unable to reach /metrics endpoint at $HOSTNAME.netbird.selfhosted:8082"
  exit 1
else
  echo "/metrics endpoint is reachable."
  if [ "$DISPLAY_OUTPUTS" = true ]; then
    echo "Output:"
    echo "$METRICS_OUTPUT"
  fi
fi