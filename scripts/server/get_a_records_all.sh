#!/bin/bash

# Run docker ps to grab container names

# container_names=$(docker ps --format '{{.Names}}')
readarray -t container_names < <(docker ps --format '{{.Names}}')
# Check if the command was successful
if [ $? -ne 0 ]; then
	echo "Failed to retrieve container names."
	exit 1
fi

websites=()
containers=()

# Loop through each container names and use docker inspect wp_jsjinc | jq -c '.[].Config.Env[0]' | cut -d= -f2 | sed 's/"//' to find the website.

for container in "${container_names[@]}"; do
	echo "Processing container: $container"
	if ! website=$(docker inspect "$container" | jq -r '.[].Config.Env[] | select(test("^WP_HOME="))' | cut -d= -f2); then
		echo "Failed to retrieve website for container $container."
		continue
	fi
	echo "website result: $website"
	websites+=("$website")
	containers+=("$container")
done

# Print all websites
mkdir -p "$HOME/logs/a_records"

success_count=0
fail_count=0
success_sites=()
fail_sites=()

for ((i=0; i<${#websites[@]}; i++)); do
    website="${websites[i]}"
    container="${containers[i]}"
    echo "Website: $website"
    echo "Container: $container"

    if [ -z "$website" ]; then
        echo "No website found for container $container. Skipping..."
        continue
    fi

    # Strip protocol and www.
    clean_website="${website#http://}"
    clean_website="${clean_website#https://}"
    clean_website="${clean_website#www.}"

    mkdir -p "$HOME/logs/a_records/$container"
    ls "$HOME/logs/a_records/$container"
    echo "Running get_a_records.sh for $container with website $clean_website"
	A_RECORDS_PATH=$HOME/logs/a_records/"$container"

    /var/opt/scripts/get_a_records.sh --url "$clean_website" --record-response-path "$A_RECORDS_PATH/record_response.json" --zone-response-path "$A_RECORDS_PATH/zone_response.json" --verbose > "$A_RECORDS_PATH/get_a_records.log" 2>&1
    if [ $? -ne 0 ]; then
        echo "Failed to run get_a_records.sh for $clean_website. Check the log file for details."
        fail_count=$((fail_count+1))
        fail_sites+=("$clean_website")
        # Run an a record check for the website via dig

        echo "Running dig for $clean_website"
        dig_output=$(dig +short "$clean_website" A)
        if [ $? -ne 0 ]; then
            echo "Failed to run dig for $clean_website."
            echo "Please check the website URL and try again."
        else
            echo "A records for $clean_website via dig:"
            echo "$dig_output" > $HOME/logs/a_records/"$container"/dig_a_records.log
            echo "Log saved to $HOME/logs/a_records/$container/dig_a_records.log"
        fi
        echo "Log saved to $HOME/logs/a_records/$container/get_a_records.log"
        echo "Please check the log file for details."
        echo "";
    else
        echo "Successfully ran get_a_records.sh for $clean_website. Log saved to $HOME/logs/a_records/$container/get_a_records.log"
        success_count=$((success_count+1))
        success_sites+=("$clean_website")
    fi
    echo ""
done

# Print summary log
summary_log="$HOME/logs/a_records/summary.log"
{
    echo "Cloudflare DNS A Record Summary"
    echo "--------------------------------"
    echo "Sites with Cloudflare DNS records: $success_count"
    for site in "${success_sites[@]}"; do
        echo "  - $site"
    done
    echo ""
    echo "Sites without Cloudflare DNS records: $fail_count"
    for site in "${fail_sites[@]}"; do
        echo "  - $site"
    done
} > "$summary_log"

echo "Summary written to $summary_log"
