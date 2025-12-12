# WordPress Update Cron Jobs

## Cron Job Entries

```bash
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
```

## Key Features of This Schedule:

1. **Staggered Timing**: Each update type runs at different times to distribute load throughout the day
2. **No Backups**: Using `--no-backup` since these are frequent automated updates (you might want backups for core updates)
3. **Separate Logs**: Each update type has its own log file for easier monitoring
4. **All Containers**: Updates all WordPress containers automatically
5. **Non-Interactive**: Runs without requiring user input

## Optional Enhancements:

If you want to include backups for core updates (recommended), change the core update line to:
```bash
0 1 * * * /var/opt/scripts/wp-update-suite/run.sh --all-containers --non-interactive --update-core >> /var/log/wp-core-updates.log 2>&1
```

You can also combine multiple update types in a single cron job if you prefer fewer scheduled tasks. For example, a combined plugin + theme + DB schema update could be:
```bash
0 6 * * * /var/opt/scripts/wp-update-suite/run.sh --all-containers --non-interactive --no-backup --update-plugins all --update-themes all --check-update-db-schema >> /var/log/wp-combined-updates.log 2>&1
```

## Installation Instructions:

1. Make sure the script has execute permissions:
   ```bash
   chmod +x /var/opt/scripts/wp-update-suite/run.sh
   ```

2. Create the log directory if it doesn't exist:
   ```bash
   mkdir -p /var/log
   ```

3. Add these entries to your crontab:
   ```bash
   crontab -e
   ```

4. Paste the cron entries above into your crontab file.

5. Verify the cron jobs are scheduled:
   ```bash
   crontab -l
   ```