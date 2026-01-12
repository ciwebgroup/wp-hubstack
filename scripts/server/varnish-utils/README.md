varnish-utils — Dockerized Varnish helper

This repository contains a small Python CLI that combines the behavior of
`test-varnish.sh` and `clear-varnish-cache.sh` into a single containerized
utility.

Quick start
-----------

Build the image:

  docker compose build

Run tests (example):

  docker compose run --rm varnish-utils test --sites "example.com,https://httpbin.org"

Use the clear command (dry-run first):

  docker compose run --rm varnish-utils clear --sites "example.com" --action host --dry-run

Issue a real ban:

  docker compose run --rm varnish-utils clear --sites "example.com" --action host

List current bans:

  docker compose run --rm varnish-utils clear --action list

Restart varnish (full flush — careful!):

  docker compose run --rm varnish-utils clear --action full

Notes
-----
- The container needs access to Docker on the host; docker-compose mounts
  /var/run/docker.sock into the container so the `docker` CLI can run
  `docker exec` / `docker restart` commands.
- The tool uses Python + requests for HTTP checks and shells out to `docker`
  for varnishadm/varnishstat interactions.
