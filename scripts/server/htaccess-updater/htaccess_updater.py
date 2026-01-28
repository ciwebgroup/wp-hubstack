import argparse
import io
import json
import logging
import subprocess
import sys
import tarfile
import time
import typing
from dataclasses import dataclass
from pathlib import Path

import docker
import requests
from docker.models.containers import Container
from requests.exceptions import RequestException

# Configure Logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - [%(levelname)s] - %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger(__name__)

# Constants
HTACCESS_PATH = "/var/www/html/.htaccess"
BACKUP_SUFFIX = ".backup"

# Block access to log files in WordPress directories
BLOCK_RULES = """
# BEGIN Block Log Files
# Block debug.log
<Files "debug.log">
    <IfModule mod_authz_core.c>
        Require all denied
    </IfModule>
    <IfModule !mod_authz_core.c>
        Order Allow,Deny
        Deny from all
    </IfModule>
</Files>

# Block error_log
<Files "error_log">
    <IfModule mod_authz_core.c>
        Require all denied
    </IfModule>
    <IfModule !mod_authz_core.c>
        Order Allow,Deny
        Deny from all
    </IfModule>
</Files>

# Block php_errorlog
<Files "php_errorlog">
    <IfModule mod_authz_core.c>
        Require all denied
    </IfModule>
    <IfModule !mod_authz_core.c>
        Order Allow,Deny
        Deny from all
    </IfModule>
</Files>

# Block all log files using pattern matching
<FilesMatch "\.(log|log\.[0-9]+)$">
    <IfModule mod_authz_core.c>
        Require all denied
    </IfModule>
    <IfModule !mod_authz_core.c>
        Order Allow,Deny
        Deny from all
    </IfModule>
</FilesMatch>
# END Block Log Files
"""

@dataclass
class Config:
    container_pattern: str
    dry_run: bool
    include: typing.List[str]
    exclude: typing.List[str]
    local_htaccess_path: typing.Optional[str]
    skip_health_check: bool
    backup: bool
    check_htaccess_volume: bool

def get_docker_client() -> docker.DockerClient:
    try:
        return docker.from_env()
    except docker.errors.DockerException as e:
        logger.error(f"Could not connect to Docker. Is the socket mounted? Error: {e}")
        sys.exit(1)

def get_target_containers(client: docker.DockerClient, config: Config) -> typing.List[Container]:
    """Filters containers based on pattern, include, and exclude flags."""
    all_containers = client.containers.list()
    targets: typing.List[Container] = []
    
    # If specific includes are provided, we ignore the general pattern entirely
    use_exclusive_include = len(config.include) > 0

    for container in all_containers:
        name = container.name
        
        # Check explicit exclude first
        if name in config.exclude:
            continue

        if use_exclusive_include:
            # "Include" mode: Only accept if explicitly listed
            if name in config.include:
                targets.append(container)
        else:
            # "Pattern" mode: Accept if it matches the prefix
            if name.startswith(config.container_pattern):
                targets.append(container)

    return targets

def read_file_from_container(container: Container, path: str) -> typing.Optional[bytes]:
    """Reads a file from a container, returning bytes or None if not found."""
    try:
        # get_archive returns a tuple (generator, stat)
        bits, _ = container.get_archive(path)
        file_obj = io.BytesIO()
        for chunk in bits:
            file_obj.write(chunk)
        file_obj.seek(0)
        
        # Extract content from tar stream
        with tarfile.open(fileobj=file_obj) as tar:
            member = tar.next()
            if member is None:
                return None
            extracted_f = tar.extractfile(member)
            if extracted_f:
                return extracted_f.read()
            return None
    except docker.errors.NotFound:
        return None
    except Exception as e:
        logger.error(f"Error reading {path} from {container.name}: {e}")
        return None

def write_file_to_container(container: Container, path: str, content: bytes) -> bool:
    """Writes bytes to a file in the container using tar archive."""
    try:
        # Create a tar archive in memory
        tar_stream = io.BytesIO()
        info = tarfile.TarInfo(name=path.split('/')[-1])
        info.size = len(content)
        info.mtime = time.time()
        
        with tarfile.open(fileobj=tar_stream, mode='w') as tar:
            tar.addfile(info, io.BytesIO(content))
        
        tar_stream.seek(0)
        
        # Put archive expects the *parent directory* as the path
        parent_dir = "/".join(path.split('/')[:-1])
        container.put_archive(parent_dir, tar_stream)
        return True
    except Exception as e:
        logger.error(f"Failed to write to {container.name}: {e}")
        return False

def get_public_url(container: Container) -> typing.Optional[str]:
    """Attempts to determine the URL from WP_HOME env var, falling back to localhost ports."""
    # Reload container attributes to ensure fresh network settings
    container.reload()

    # Strategy 1: Check WP_HOME environment variable
    # This mimics `docker inspect | jq '.[].Config.Env'`
    env_vars = container.attrs.get('Config', {}).get('Env', [])
    for var in env_vars:
        if var.startswith('WP_HOME='):
            return var.split('=', 1)[1]

    # Strategy 2: Fallback to mapped ports
    ports = container.attrs.get('NetworkSettings', {}).get('Ports', {})
    
    # Look for port 80 mappings
    port_80 = ports.get('80/tcp')
    if port_80 and len(port_80) > 0:
        host_port = port_80[0].get('HostPort')
        if host_port:
            return f"http://localhost:{host_port}"
            
    # Fallback: check 443
    port_443 = ports.get('443/tcp')
    if port_443 and len(port_443) > 0:
        host_port = port_443[0].get('HostPort')
        if host_port:
            return f"https://localhost:{host_port}"
            
    return None

def verify_site_health(url: str) -> bool:
    """Returns True if status is 200, False otherwise."""
    try:
        # We suppress SSL warnings here since we are likely hitting localhost/IPs with self-signed certs
        requests.packages.urllib3.disable_warnings() # type: ignore
        response = requests.get(url, timeout=5, verify=False)
        if response.status_code == 200:
            return True
        logger.warning(f"Health check failed for {url}. Status: {response.status_code}")
        return False
    except RequestException as e:
        logger.error(f"Health check connection error for {url}: {e}")
        return False

def get_compose_file_from_container(container: Container) -> typing.Optional[str]:
    """Extract docker-compose.yml path from container labels."""
    try:
        container.reload()
        labels = container.attrs.get('Config', {}).get('Labels', {})
        compose_files = labels.get('com.docker.compose.project.config_files', '')
        
        if compose_files:
            # Can be comma-separated list; take the first one
            extracted_path = compose_files.split(',')[0].strip()
            logger.debug(f"Extracted compose path from labels: {extracted_path}")
            
            # Check if file exists at extracted path
            if Path(extracted_path).exists():
                return extracted_path
            
            # Try variations if exact path doesn't exist
            compose_dir = Path(extracted_path).parent
            if compose_dir.exists():
                # Try common compose file names in the directory
                for filename in ['docker-compose.yml', 'docker-compose.yaml', 'compose.yml', 'compose.yaml']:
                    candidate = compose_dir / filename
                    if candidate.exists():
                        logger.info(f"Found compose file at {candidate} (label pointed to {extracted_path})")
                        return str(candidate)
            
            # Path from label doesn't exist and we couldn't find alternatives
            logger.warning(f"Compose file from label ({extracted_path}) does not exist and no alternatives found")
            return extracted_path  # Return it anyway so the caller can log the error
        
        return None
    except Exception as e:
        logger.error(f"Error getting compose file for {container.name}: {e}")
        return None

def check_and_update_htaccess_volume(container: Container, config: Config) -> None:
    """Check if htaccess volume mount exists in docker-compose.yml and add if missing."""
    logger.info(f"Checking htaccess volume for container: {container.name}")
    
    if config.dry_run:
        logger.info(f"[DRY-RUN] Would check volume mount for {container.name}")
        logger.info(f"[DRY-RUN] Would ensure: /var/opt/shared/.htaccess:/var/www/html/.htaccess:ro")
        return
    
    # Get docker-compose.yml path
    compose_path = get_compose_file_from_container(container)
    if not compose_path:
        logger.warning(f"Could not find docker-compose.yml for {container.name}. Skipping.")
        return
    
    logger.info(f"Compose path from container: {compose_path}")
    
    if not Path(compose_path).exists():
        logger.error(f"Compose file does not exist: {compose_path}. Skipping.")
        return
    
    logger.info(f"Found compose file: {compose_path}")
    
    # Import YAML library
    try:
        import yaml
    except ImportError:
        logger.error("PyYAML not installed. Cannot check docker-compose.yml files.")
        return
    
    # Read compose file
    try:
        with open(compose_path, 'r') as f:
            compose_data = yaml.safe_load(f)
    except Exception as e:
        logger.error(f"Failed to parse {compose_path}: {e}")
        return
    
    # Find the service for this container
    services = compose_data.get('services', {})
    service_name = None
    
    # Try to find service by container_name label or name matching
    for svc_name, svc_config in services.items():
        container_name_label = svc_config.get('container_name')
        if container_name_label == container.name or svc_name == container.name:
            service_name = svc_name
            break
    
    if not service_name:
        logger.warning(f"Could not find service definition for {container.name} in {compose_path}")
        return
    
    logger.info(f"Found service: {service_name}")
    
    # Check if volume exists
    service_config = services[service_name]
    volumes = service_config.get('volumes', [])
    target_volume = '/var/opt/shared/.htaccess:/var/www/html/.htaccess:ro'
    
    volume_exists = any(
        vol == target_volume or
        (isinstance(vol, str) and vol.split(':')[1] == '/var/www/html/.htaccess' if ':' in vol else False)
        for vol in volumes
    )
    
    if volume_exists:
        logger.info(f"htaccess volume already configured for {container.name}")
        return
    
    logger.info(f"htaccess volume NOT found. Adding to {compose_path}...")
    
    # Create backup
    backup_path = compose_path + BACKUP_SUFFIX
    backup_created = False
    
    if config.backup:
        try:
            with open(compose_path, 'r') as f:
                original_content = f.read()
            with open(backup_path, 'w') as f:
                f.write(original_content)
            logger.info(f"Created backup at {backup_path}")
            backup_created = True
        except Exception as e:
            logger.error(f"Failed to create backup: {e}. Aborting.")
            return
    else:
        logger.info("Backup disabled (--no-backup). Proceeding without backup.")
    
    # Add volume
    if not isinstance(volumes, list):
        volumes = []
    volumes.append(target_volume)
    services[service_name]['volumes'] = volumes
    
    # Write updated compose file
    try:
        with open(compose_path, 'w') as f:
            yaml.dump(compose_data, f, default_flow_style=False, sort_keys=False)
        logger.info(f"Updated {compose_path} with htaccess volume")
        logger.info(f"MANUAL ACTION REQUIRED: Run 'docker compose up -d {service_name}' in {Path(compose_path).parent} to apply changes")
    except Exception as e:
        logger.error(f"Failed to write updated compose file: {e}")
        return
    
    # Note: We skip automatic container restart because docker CLI is not available in this container
    # The user needs to manually restart containers after running this tool
    logger.info(f"Compose file updated successfully for {container.name}. Container restart required to apply volume mount.")

def process_container(container: Container, config: Config) -> None:
    logger.info(f"Processing container: {container.name}")

    if config.dry_run:
        logger.info(f"[DRY-RUN] Would check {HTACCESS_PATH} in {container.name}")
        return

    # 1. Read existing .htaccess
    current_content_bytes = read_file_from_container(container, HTACCESS_PATH)
    if current_content_bytes is None:
        logger.error(f"Could not find {config.htaccess_path} in {container.name}. Skipping.")
        return

    current_content = current_content_bytes.decode('utf-8', errors='ignore')

    # Check if rules already exist
    rules_already_present = "Block Log Files" in current_content
    backup_created = False
    
    if rules_already_present:
        logger.info(f"Rules already present in {container.name}.")
    else:
        # 2. Create Backup (if enabled)
        if config.backup:
            logger.info(f"Creating backup at {HTACCESS_PATH}{BACKUP_SUFFIX}")
            if not write_file_to_container(container, HTACCESS_PATH + BACKUP_SUFFIX, current_content_bytes):
                logger.error("Failed to create backup. Aborting modification.")
                return
            backup_created = True
        else:
            logger.info("Backup disabled (--no-backup). Proceeding without backup.")

        # 3. Append Rules
        new_content = current_content + "\n" + BLOCK_RULES + "\n"
        logger.info("Injecting rules...")
        if not write_file_to_container(container, HTACCESS_PATH, new_content.encode('utf-8')):
            logger.error("Failed to write new .htaccess.")
            return

    # 4. Verify
    if config.skip_health_check:
        logger.info(f"Skipping health check for {container.name} (--skip-health-check enabled)")
        return
    
    url = get_public_url(container)
    if not url:
        logger.warning(f"Could not determine public URL for {container.name}. Cannot verify health.")
        # If we can't find a URL, we stop here (no rollback) unless requirements dictate otherwise.
        return

    logger.info(f"Verifying health at {url}...")
    is_healthy = verify_site_health(url)

    if not is_healthy:
        logger.error(f"Health check FAILED for {container.name}.")
        if not rules_already_present:
            # Only rollback if we made changes
            if backup_created:
                logger.info("Rolling back...")
                if write_file_to_container(container, HTACCESS_PATH, current_content_bytes):
                    logger.info("Rollback successful.")
                else:
                    logger.critical("Rollback FAILED. Manual intervention required!")
            else:
                logger.critical("Health check failed but no backup was created (--no-backup). Manual intervention required!")
        else:
            logger.warning("Rules were already present. No rollback to perform.")
    else:
        logger.info(f"Health check passed for {container.name}.")

def write_local_htaccess(path: str, dry_run: bool, backup: bool, skip_health_check: bool, client: typing.Optional[docker.DockerClient] = None) -> None:
    """Write BLOCK_RULES to a local .htaccess file with health check against all wp_ containers."""
    if dry_run:
        logger.info(f"[DRY-RUN] Would write log-blocking rules to local {path}")
        if backup:
            logger.info(f"[DRY-RUN] Would create backup at {path}{BACKUP_SUFFIX}")
        else:
            logger.info("[DRY-RUN] Backup would be disabled (--no-backup)")
        if not skip_health_check:
            logger.info("[DRY-RUN] Would perform health checks against all wp_ containers")
            logger.info("[DRY-RUN] Would rollback if any container returns non-200 status")
        else:
            logger.info("[DRY-RUN] Health checks would be skipped (--skip-health-check)")
        return
    
    try:
        # Read existing content if file exists
        existing_content = ""
        backup_path = path + BACKUP_SUFFIX
        try:
            with open(path, 'r', encoding='utf-8') as f:
                existing_content = f.read()
        except FileNotFoundError:
            logger.info(f"Creating new .htaccess at {path}")
        
        # Check if rules already exist
        if "Block Log Files" in existing_content:
            logger.info(f"Rules already present in {path}. Skipping.")
            return
        
        # Create backup (if enabled)
        backup_created = False
        if backup and existing_content:
            with open(backup_path, 'w', encoding='utf-8') as f:
                f.write(existing_content)
            logger.info(f"Created backup at {backup_path}")
            backup_created = True
        elif not backup:
            logger.info("Backup disabled (--no-backup). Proceeding without backup.")
        
        # Write new content
        new_content = existing_content + "\n" + BLOCK_RULES + "\n"
        with open(path, 'w', encoding='utf-8') as f:
            f.write(new_content)
        logger.info(f"Successfully wrote to {path}")
        
        # Health check against all wp_ containers
        if not skip_health_check:
            logger.info("Performing health checks against all wp_ containers...")
            
            # Get Docker client if not provided
            if client is None:
                try:
                    client = get_docker_client()
                except SystemExit:
                    logger.warning("Cannot connect to Docker for health checks. Skipping health verification.")
                    return
            
            # Get all wp_ containers
            all_containers = client.containers.list()
            wp_containers = [c for c in all_containers if c.name.startswith("wp_")]
            
            if not wp_containers:
                logger.info("No wp_ containers found for health check.")
                return
            
            logger.info(f"Found {len(wp_containers)} wp_ containers to verify.")
            
            # Check each container's health
            failed_checks = []
            for container in wp_containers:
                url = get_public_url(container)
                if not url:
                    logger.warning(f"Could not determine URL for {container.name}. Skipping health check for this container.")
                    continue
                
                logger.info(f"Checking {container.name} at {url}...")
                is_healthy = verify_site_health(url)
                
                if not is_healthy:
                    failed_checks.append((container.name, url))
            
            # Rollback if any checks failed
            if failed_checks:
                logger.error(f"Health check FAILED for {len(failed_checks)} container(s):")
                for name, url in failed_checks:
                    logger.error(f"  - {name} ({url})")
                
                if backup_created:
                    logger.info(f"Rolling back local .htaccess from {backup_path}...")
                    try:
                        with open(backup_path, 'r', encoding='utf-8') as f:
                            original_content = f.read()
                        with open(path, 'w', encoding='utf-8') as f:
                            f.write(original_content)
                        logger.info("Rollback successful.")
                    except Exception as rollback_error:
                        logger.critical(f"Rollback FAILED: {rollback_error}. Manual intervention required!")
                else:
                    logger.critical("Health checks failed but no backup was created (--no-backup). Manual intervention required!")
            else:
                logger.info("All health checks passed.")
        else:
            logger.info("Skipping health checks (--skip-health-check enabled).")
        
    except Exception as e:
        logger.error(f"Failed to write local .htaccess at {path}: {e}")

def main() -> None:
    parser = argparse.ArgumentParser(description="Update WP .htaccess files in Docker containers.")
    parser.add_argument("--container-pattern", default="wp_", help="Prefix for container names (default: wp_)")
    parser.add_argument("--dry-run", action="store_true", help="Simulate without making changes")
    parser.add_argument("--include", action="append", default=[], help="Specific container names to include (overrides pattern)")
    parser.add_argument("--exclude", action="append", default=[], help="Specific container names to exclude")
    parser.add_argument("--htaccess", nargs="?", const="/app/.htaccess", default=None, help="Write to local .htaccess file (default path: /app/.htaccess if flag is used without value)")
    parser.add_argument("--skip-health-check", action="store_true", help="Skip health check verification after updating .htaccess")
    parser.add_argument("--no-backup", action="store_true", help="Disable automatic backup creation before modifying .htaccess")
    parser.add_argument("--check-htaccess-volume", action="store_true", help="Check and ensure /var/opt/shared/.htaccess:/var/www/html/.htaccess:ro volume exists in docker-compose.yml")
    
    args = parser.parse_args()
    config = Config(
        container_pattern=args.container_pattern,
        dry_run=args.dry_run,
        include=args.include,
        exclude=args.exclude,
        local_htaccess_path=args.htaccess,
        skip_health_check=args.skip_health_check,
        backup=not args.no_backup,
        check_htaccess_volume=args.check_htaccess_volume
    )

    client = get_docker_client()

    # Write to local .htaccess if flag was provided
    if config.local_htaccess_path:
        logger.info(f"Writing to local .htaccess at {config.local_htaccess_path}")
        write_local_htaccess(config.local_htaccess_path, config.dry_run, config.backup, config.skip_health_check, client)
        logger.info("Local .htaccess write complete.")
        # Only return early if no other operations are requested
        if not config.check_htaccess_volume:
            logger.info("Skipping container .htaccess processing.")
            return

    targets = get_target_containers(client, config)

    if not targets:
        logger.info("No matching containers found.")
        return

    logger.info(f"Found {len(targets)} target containers.")

    # Check htaccess volume if requested
    if config.check_htaccess_volume:
        logger.info("Checking htaccess volume mounts in docker-compose.yml files...")
        for container in targets:
            check_and_update_htaccess_volume(container, config)
        logger.info("htaccess volume check complete.")
        return

    # Process container .htaccess files (only if --htaccess was not used)
    if not config.local_htaccess_path:
        for container in targets:
            process_container(container, config)

if __name__ == "__main__":
    main()