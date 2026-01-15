#!/bin/bash

docker compose run --rm traefik-netbird-config add -d /traefik -c /additions.yml --apply-iptables