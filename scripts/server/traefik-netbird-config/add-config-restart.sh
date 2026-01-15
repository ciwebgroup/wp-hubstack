#!/bin/bash

/var/opt/scripts/traefik-netbird-config/add-config.sh && (cd /var/opt/services/traefik && docker compose down && docker compose up -d) && sleep 5 && /var/opt/scripts/traefik-netbird-config/test-endpoints.sh