# Uptime Kuma Docker Container Monitor

This script automatically manages Uptime Kuma monitors for WordPress Docker containers by:

1. Extracting WordPress container names from `docker ps` (containers starting with `wp_`)
2. Extracting URLs from container inspect data via `docker inspect`
3. Checking if websites are already monitored on the attached Uptime Kuma instance
4. Adding new monitors for websites that aren't already monitored
5. Loading credentials and configuration from `.env` variables

## Features

- **Docker Integration**: Automatically discovers running containers
- **URL Extraction**: Extracts URLs from:
  - `WP_HOME` environment variables (WordPress containers)
  - Traefik router labels (`Host()` rules)
- **Smart Monitoring**: Only adds monitors for websites not already monitored
- **Dry Run Mode**: Test without making actual changes
- **Container Filtering**: By default only processes WordPress containers (starting with `wp_`), but can be configured to process all containers
- **Comprehensive Logging**: Detailed logging with configurable levels

## Setup

### 1. Environment Configuration

Copy the sample environment file and configure your Uptime Kuma instance:

```bash
cp uptime-kuma-env-sample.txt .env
```

Edit `.env` with your Uptime Kuma details:

```bash
# Base URL of your Uptime Kuma instance (include protocol)
UPTIME_KUMA_URL=https://your-uptime-kuma-instance.com

# Uptime Kuma login credentials (same as web interface)
UPTIME_KUMA_USERNAME=your-username
UPTIME_KUMA_PASSWORD=your-password
```

### 2. Setting Up Authentication

This script uses the same username and password you use to log into the Uptime Kuma web interface. No API tokens are required as the script uses the WebSocket API for communication.

### 3. Python Dependencies

The script requires these Python packages:
- `python-dotenv` - For loading environment variables
- `uptime-kuma-api` - Official Uptime Kuma WebSocket API client

## Usage

### Quick Start (Recommended)

Use the bash runner script which handles virtual environment setup:

```bash
# Run with default settings (WordPress containers only)
./run.sh

# Run in dry-run mode to test
./run.sh --dry-run

# Process all containers (not just WordPress)
./run.sh --container-filter ""

# Enable verbose logging
./run.sh --verbose
```

### Direct Python Usage

```bash
# Set up virtual environment manually
python3 -m venv venv-uptime-kuma
source venv-uptime-kuma/bin/activate
pip install -r requirements-uptime-kuma.txt

# Run the script
python3 ./main.py --help
```

## Command Line Options

- `--dry-run`: Simulate operations without making changes
- `--container-filter PATTERN`: Regex pattern to filter container names
- `--verbose`: Enable verbose logging
- `--help`: Show help message

## Examples

### Monitor WordPress Containers (Default)
```bash
./run.sh
```

### Monitor All Containers
```bash
./run.sh --container-filter ""
```

### Test Without Making Changes
```bash
./run.sh --dry-run --verbose
```

### Monitor Specific Container Pattern
```bash
./run.sh --container-filter "^(wp_|app_)"
```

## URL Extraction Methods

The script extracts URLs from containers using these methods:

### 1. WordPress Environment Variables
Looks for `WP_HOME` environment variables in containers:
```bash
docker inspect container_name | grep WP_HOME
```

### 2. Traefik Labels
Extracts hostnames from Traefik router labels:
```bash
traefik.http.routers.example.rule=Host(`example.com`)
```

## Monitor Configuration

When adding monitors, the script configures them with:
- **Type**: HTTP monitoring
- **Name**: `{container_name} - {domain}`
- **Method**: GET
- **Interval**: 60 seconds
- **Timeout**: 30 seconds
- **Max Retries**: 3
- **Tags**: `auto-generated`, `docker`, `{container_name}`

## Logging

The script creates two types of logs:
- **Console Output**: Real-time progress and status
- **Log File**: `uptime-kuma-monitor.log` with detailed information

Log levels:
- `INFO`: General operation status
- `DEBUG`: Detailed debugging information (use `--verbose`)
- `WARNING`: Non-critical issues
- `ERROR`: Critical errors

## Troubleshooting

### Common Issues

1. **"UPTIME_KUMA_URL environment variable is required"**
   - Ensure your `.env` file exists and contains the correct variables
   - Check that the URL includes the protocol (http:// or https://)

2. **"Failed to connect to Uptime Kuma API"**
   - Verify your Uptime Kuma instance is accessible
   - Check your username and password are correct
   - Ensure the WebSocket connection is not blocked by firewalls

3. **"No containers found to process"**
   - Ensure Docker is running and you have containers
   - Check your container filter pattern if using one

4. **"No URLs found for container"**
   - Container may not have WP_HOME environment variable
   - Container may not have Traefik labels configured

### Debug Mode

Run with verbose logging to see detailed information:

```bash
./run.sh --dry-run --verbose
```

### Manual Testing

Test individual components:

```bash
# Test Docker connectivity
docker ps --format "{{.Names}}"

# Test container inspection
docker inspect container_name

# Test script in dry-run mode
./run.sh --dry-run --verbose
```

## Security Considerations

- Store API tokens securely in `.env` files
- Never commit `.env` files to version control
- Use HTTPS for Uptime Kuma instances when possible
- Consider using limited-scope API tokens

## Integration with Existing Scripts

This script follows the same patterns as other scripts in the codebase:
- Uses `docker ps --format "{{.Names}}"` for container discovery
- Uses `docker inspect` for container metadata
- Follows similar logging and error handling patterns
- Uses `.env` files for configuration

## Contributing

When modifying this script:
1. Follow the existing code patterns
2. Add appropriate logging
3. Update this documentation
4. Test with `--dry-run` first
5. Consider backward compatibility 