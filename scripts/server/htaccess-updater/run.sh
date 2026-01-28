#!/bin/bash

docker compose build --no-cache

docker compose run --rm htaccess-updater --check-htaccess-volume

for site in /var/opt/sites/*; do
  if [ -d "$site" ]; then
	(cd "$site" && docker compose down && docker compose up -d)
  fi

  # Strip site from /var/opt/sites/* path
  site_name=$(basename "$site")

  # Curl-check the site to check the status code

  status_code=$(curl -o /dev/null -s -L -w "%{http_code}\n" "http://$site_name")

  if [ "$status_code" -ne 200 ]; then
	echo "Warning: Site $site_name returned status code $status_code"
  fi

done

docker compose run --rm htaccess-updater --htaccess /app/.htaccess --skip-health-check
