#!/bin/bash

# 1. Get a list of all running container names starting with 'wp_'
CONTAINERS=$(docker ps --format '{{.Names}}' | grep '^wp_')

if [ -z "$CONTAINERS" ]; then
    echo "No containers found starting with 'wp_'. Exiting."
    exit 1
fi

for CONTAINER in $CONTAINERS; do
    echo "----------------------------------------------------------"
    echo "Processing: $CONTAINER"
    echo "----------------------------------------------------------"

    # 2. Set Ownership and Permissions (Running as Root -u 0)
    # Removing -it for non-interactive execution
    echo "> Aligning ownership to www-data..."
    docker exec -u 0 "$CONTAINER" chown -R www-data:www-data /var/www/html

    echo "> Setting directory permissions to 0775..."
    docker exec -u 0 "$CONTAINER" find /var/www/html -type d -exec chmod 775 {} +

    echo "> Setting file permissions to 0664..."
    docker exec -u 0 "$CONTAINER" find /var/www/html -type f -exec chmod 664 {} +

    # 3. Install and Activate the plugin
    echo "> Installing wp-security-audit-log..."
    docker exec -u 0 "$CONTAINER" wp plugin install wp-security-audit-log --activate --allow-root

    # 4. Execute the specific WSAL CLI commands for a "silent" setup
    echo "> Configuring stealth and notification settings..."

    # Remove the setup wizard
    docker exec -u 0 "$CONTAINER" wp wsal_cli_commands remove_wizard --allow-root

    # Hide the plugin from the plugins list
    docker exec -u 0 "$CONTAINER" wp wsal_cli_commands set_hide_plugin 1 --allow-root

    # Disable the login page notification
    docker exec -u 0 "$CONTAINER" wp wsal_cli_commands login_page_notification --enabled=false --allow-root

    # Remove daily and weekly email notifications
    docker exec -u 0 "$CONTAINER" wp wsal_cli_commands remove_daily_notification --allow-root
    docker exec -u 0 "$CONTAINER" wp wsal_cli_commands remove_weekly_notification --allow-root

    # Set a retention policy (6 months)
    docker exec -u 0 "$CONTAINER" wp wsal_cli_commands set_retention --enabled=true --pruning-value=6 --pruning-unit=months --allow-root

    echo "Done with $CONTAINER"
done

echo "----------------------------------------------------------"
echo "All sites processed successfully in non-interactive mode."