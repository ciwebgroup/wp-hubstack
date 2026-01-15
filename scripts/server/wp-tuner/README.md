# WordPress Container Fine-Tuning Tool

A comprehensive Python-based diagnostic and auto-tuning tool for identifying and fixing CPU starvation and resource allocation issues in dockerized WordPress containers.

## Features

- 🔍 **Comprehensive Diagnostics**: Analyzes CPU, memory, Apache, PHP, Redis, and plugin configurations
- 🔧 **Auto-Patching**: Automatically generates and applies optimized configurations
- 📊 **Detailed Reports**: Clear, actionable performance reports with recommendations
- 🐳 **Dockerized**: Runs in a container with all dependencies included
- 🛡️ **Type-Safe**: Full MyPy type checking for reliability

## What It Detects

- CPU starvation (too many Apache workers for available CPU cores)
- Memory pressure and misconfigurations
- Apache MPM inefficiencies
- Redis connectivity issues
- High error rates
- PHP memory limit problems
- System load issues

## Quick Start

### Build the Tool

```bash
cd /var/opt/scripts/wp-container-fine-tuning
docker-compose build
```

### Run Diagnostics Only

```bash
docker-compose run --rm wp-tuner \
  wp_malibuheatingandair \
  --site-path /var/opt/sites/malibuheatingandair.com
```

### Run Diagnostics with Auto-Fix

```bash
docker-compose run --rm wp-tuner \
  wp_malibuheatingandair \
  --site-path /var/opt/sites/malibuheatingandair.com \
  --auto-fix
```

### Preview Changes (Dry-Run)

```bash
docker-compose run --rm wp-tuner \
  wp_malibuheatingandair \
  --site-path /var/opt/sites/malibuheatingandair.com \
  --dry-run
```

### Custom Resource Allocation

```bash
docker-compose run --rm wp-tuner \
  wp_malibuheatingandair \
  --site-path /var/opt/sites/malibuheatingandair.com \
  --auto-fix \
  --target-cpus 4 \
  --target-memory-gb 2
```

## What Auto-Fix Does

When `--auto-fix` is enabled, the tool will:

1. **Update docker-compose.yml**: Adjust CPU and memory limits
2. **Create mpm_prefork.conf**: Optimized Apache MPM configuration
3. **Create php.ini**: Aligned PHP memory limits
4. **Update volumes**: Mount new configuration files

After auto-fix, you must restart the container:

```bash
cd /var/opt/sites/malibuheatingandair.com
docker-compose down && docker-compose up -d
```

## Example Output

```
📊 WORDPRESS CONTAINER DIAGNOSTIC REPORT
================================================================================

🐳 Container: wp_malibuheatingandair
   CPU Limit: 1.5 cores
   CPU Usage: 147.20%
   Memory Limit: 1.0G
   Memory Usage: 99.11%
   PIDs: 151

🌐 Apache Configuration:
   MPM Module: mpm_prefork
   MaxRequestWorkers: 150
   Current Processes: 150
   Utilization: 150/150 (100.0%)

🔍 Recommendations:
   ⚠️  CRITICAL: 150 Apache workers for 1.5 CPUs = 100 workers/CPU. 
       Reduce MaxRequestWorkers to 22
   ⚠️  High CPU usage (147.2%). Consider increasing CPU allocation.
   ⚠️  High memory usage (99.1%). Consider increasing memory allocation.
   ⚠️  Apache at capacity: 150/150 processes.
```

## Development

### Type Checking

```bash
cd /var/opt/scripts/wp-container-fine-tuning
mypy wp_tune.py
```

### Code Formatting

```bash
black wp_tune.py
isort wp_tune.py
```

### Linting

```bash
pylint wp_tune.py
```

## Usage as Standalone Script

You can also run the script directly on the host (requires Python 3.11+):

```bash
# Install dependencies
pip install -r requirements.txt

# Run diagnostics
python wp_tune.py wp_malibuheatingandair \
  --site-path /var/opt/sites/malibuheatingandair.com

# Run with auto-fix
python wp_tune.py wp_malibuheatingandair \
  --site-path /var/opt/sites/malibuheatingandair.com \
  --auto-fix
```

## Configuration Files Generated

- **mpm_prefork.conf**: Apache prefork MPM configuration optimized for CPU count
- **mpm_event.conf**: Apache event MPM configuration (for future migration)
- **php.ini**: PHP configuration with aligned memory limits

## Recommendations Formula

- **MaxRequestWorkers** = CPUs × 10-15 (for CPU-bound workloads)
- **PHP memory_limit** = Container Memory × 0.5
- **WordPress MEMORY_LIMIT** = Container Memory × 0.75
- **Target CPUs** = Current × 2 (minimum 2.0)

## Architecture

```
wp_tune.py
├── DockerClient: Low-level Docker operations
├── WordPressAnalyzer: Diagnostic logic
├── ConfigPatcher: Configuration file generation
└── CLI: Argument parsing and reporting
```

## Requirements

- Python 3.11+
- Docker socket access (`/var/run/docker.sock`)
- Read/write access to site directories

## License

Internal tool for system administration.
