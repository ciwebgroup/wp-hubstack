import argparse
import io
import logging
import sys
import tarfile
import time
import typing
from dataclasses import dataclass

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

# The rules extracted from the PHP plugin
BLOCK_RULES = """
# BEGIN Block Debug Log
<Files "debug.log">
    <IfModule mod_authz_core.c>
        Require all denied
    </IfModule>
    <IfModule !mod_authz_core.c>
        Order Allow,Deny
        Deny from all
    </IfModule>
</Files>
# END Block Debug Log
"""

@dataclass
class Config:
    container_pattern: str
    dry_run: bool
    include: typing.List[str]
    exclude: typing.List[str]
    local_htaccess_path: typing.Optional[str]
    skip_health_check: bool

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
    rules_already_present = "Block Debug Log" in current_content
    
    if rules_already_present:
        logger.info(f"Rules already present in {container.name}.")
    else:
        # 2. Create Backup
        logger.info(f"Creating backup at {HTACCESS_PATH}{BACKUP_SUFFIX}")
        if not write_file_to_container(container, HTACCESS_PATH + BACKUP_SUFFIX, current_content_bytes):
            logger.error("Failed to create backup. Aborting modification.")
            return

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
            logger.info("Rolling back...")
            if write_file_to_container(container, HTACCESS_PATH, current_content_bytes):
                logger.info("Rollback successful.")
            else:
                logger.critical("Rollback FAILED. Manual intervention required!")
        else:
            logger.warning("Rules were already present. No rollback to perform.")
    else:
        logger.info(f"Health check passed for {container.name}.")

def write_local_htaccess(path: str, dry_run: bool) -> None:
    """Write BLOCK_RULES to a local .htaccess file."""
    if dry_run:
        logger.info(f"[DRY-RUN] Would write to local {path}")
        return
    
    try:
        # Read existing content if file exists
        existing_content = ""
        try:
            with open(path, 'r', encoding='utf-8') as f:
                existing_content = f.read()
        except FileNotFoundError:
            logger.info(f"Creating new .htaccess at {path}")
        
        # Check if rules already exist
        if "Block Debug Log" in existing_content:
            logger.info(f"Rules already present in {path}. Skipping.")
            return
        
        # Create backup
        if existing_content:
            backup_path = path + BACKUP_SUFFIX
            with open(backup_path, 'w', encoding='utf-8') as f:
                f.write(existing_content)
            logger.info(f"Created backup at {backup_path}")
        
        # Write new content
        new_content = existing_content + "\n" + BLOCK_RULES + "\n"
        with open(path, 'w', encoding='utf-8') as f:
            f.write(new_content)
        logger.info(f"Successfully wrote to {path}")
        
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
    
    args = parser.parse_args()
    config = Config(
        container_pattern=args.container_pattern,
        dry_run=args.dry_run,
        include=args.include,
        exclude=args.exclude,
        local_htaccess_path=args.htaccess,
        skip_health_check=args.skip_health_check
    )

    # Write to local .htaccess if flag was provided
    if config.local_htaccess_path:
        logger.info(f"Writing to local .htaccess at {config.local_htaccess_path}")
        write_local_htaccess(config.local_htaccess_path, config.dry_run)

    client = get_docker_client()
    targets = get_target_containers(client, config)

    if not targets:
        logger.info("No matching containers found.")
        return

    logger.info(f"Found {len(targets)} target containers.")

    for container in targets:
        process_container(container, config)

if __name__ == "__main__":
    main()