# Plugin updates - 3 times per day (6 AM, 2 PM, 10 PM)
0 6 * * * /var/opt/scripts/wp-update-suite/run.sh --all-containers --non-interactive --no-backup --update-plugins all >> /var/log/wp-plugin-updates.log 2>&1
0 14 * * * /var/opt/scripts/wp-update-suite/run.sh --all-containers --non-interactive --no-backup --update-plugins all >> /var/log/wp-plugin-updates.log 2>&1
0 22 * * * /var/opt/scripts/wp-update-suite/run.sh --all-containers --non-interactive --no-backup --update-plugins all >> /var/log/wp-plugin-updates.log 2>&1

# Theme updates - 3 times per day (8 AM, 4 PM, 12 AM)
0 8 * * * /var/opt/scripts/wp-update-suite/run.sh --all-containers --non-interactive --no-backup --update-themes all >> /var/log/wp-theme-updates.log 2>&1
0 16 * * * /var/opt/scripts/wp-update-suite/run.sh --all-containers --non-interactive --no-backup --update-themes all >> /var/log/wp-theme-updates.log 2>&1
0 0 * * * /var/opt/scripts/wp-update-suite/run.sh --all-containers --non-interactive --no-backup --update-themes all >> /var/log/wp-theme-updates.log 2>&1

# Database schema updates - 3 times per day (7 AM, 3 PM, 11 PM)
0 7 * * * /var/opt/scripts/wp-update-suite/run.sh --all-containers --non-interactive --no-backup --check-update-db-schema >> /var/log/wp-db-schema-updates.log 2>&1
0 15 * * * /var/opt/scripts/wp-update-suite/run.sh --all-containers --non-interactive --no-backup --check-update-db-schema >> /var/log/wp-db-schema-updates.log 2>&1
0 23 * * * /var/opt/scripts/wp-update-suite/run.sh --all-containers --non-interactive --no-backup --check-update-db-schema >> /var/log/wp-db-schema-updates.log 2>&1

# Core updates - Once per day (1 AM)
0 1 * * * /var/opt/scripts/wp-update-suite/run.sh --all-containers --non-interactive --no-backup --update-core >> /var/log/wp-core-updates.log 2>&1