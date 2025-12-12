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

## Log Rotation Feature

The script now supports automatic log rotation with the `--rotate-logs` flag:

### Basic Usage:
```bash
# Enable log rotation with default settings
/var/opt/scripts/wp-update-suite/run.sh --rotate-logs --all-containers --non-interactive --update-plugins all

# Use custom log configuration
/var/opt/scripts/wp-update-suite/run.sh --rotate-logs --log-config /path/to/custom-config.yaml --all-containers --non-interactive --update-plugins all

# Generate a YAML config template
/var/opt/scripts/wp-update-suite/run.sh --print-rotate-log-yaml > log-config.yaml
```

### Default Settings:
- **Log file**: `/var/log/wp-update-suite.log`
- **Max file size**: 10MB
- **Backup count**: 5 files
- **Log level**: INFO
- **Backup naming**: Numbered (`.log.1`, `.log.2`, etc.)

### Optional Timestamped Backups:
If you prefer timestamped backup filenames instead of numbered ones, you can uncomment the `namer` line in the `setup_log_rotation` function. This will create backups like:
- `wp-update-suite.log.20251212_143000`
- `wp-update-suite.log.20251211_143000`

### Custom Configuration:
Create a YAML config file (see `log-config-sample.yaml` for examples) to customize:
- Log file path and naming
- Maximum file size before rotation
- Number of backup files to keep
- Log level and format
- Date/time formatting

### Cron Jobs with Log Rotation:
```bash
# Plugin updates with log rotation
0 6 * * * /var/opt/scripts/wp-update-suite/run.sh --rotate-logs --all-containers --non-interactive --no-backup --update-plugins all

# Core updates with custom log config
0 1 * * * /var/opt/scripts/wp-update-suite/run.sh --rotate-logs --log-config /var/opt/scripts/wp-update-suite/log-config.yaml --all-containers --non-interactive --update-core
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