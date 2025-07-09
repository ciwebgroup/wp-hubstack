#!/usr/bin/env python3
"""
Uptime Kuma Docker Container Monitor Management Script

This script:
1. Extracts all container names from `docker ps`
2. Extracts URLs from container inspect data (WP_HOME env vars and Traefik labels)
3. Checks if websites are already monitored in Uptime Kuma
4. Adds new monitors for websites not yet monitored
5. Loads credentials from .env variables

Author: AI Assistant
Created: 2024
"""

import os
import sys
import subprocess
import json
import re
import logging
import argparse
import time
from typing import Dict, List, Optional, Set, Any
from dotenv import load_dotenv
from uptime_kuma_api import UptimeKumaApi, MonitorType
from urllib.parse import urlparse

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('uptime-kuma-monitor.log'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

class UptimeKumaManager:
    """Manages Uptime Kuma monitoring integration with Docker containers."""
    
    def __init__(self, dry_run: bool = False, container_filter: str = "^wp_"):
        """
        Initialize the Uptime Kuma manager.
        
        Args:
            dry_run: If True, only simulate operations without making changes
            container_filter: Regex pattern to filter container names (default: "^wp_" for WordPress containers)
        """
        self.dry_run = dry_run
        self.container_filter = re.compile(container_filter) if container_filter else None
        self.uptime_kuma_url = None
        self.uptime_kuma_username = None
        self.uptime_kuma_password = None
        self.api = None
        self.existing_monitors = {}
        
        # Load environment variables
        self._load_env_variables()
        
        # Setup session with authentication
        self._setup_session()
    
    def _load_env_variables(self):
        """Load required environment variables from .env file."""
        load_dotenv()
        
        self.uptime_kuma_url = os.getenv('UPTIME_KUMA_URL')
        self.uptime_kuma_username = os.getenv('UPTIME_KUMA_USERNAME')
        self.uptime_kuma_password = os.getenv('UPTIME_KUMA_PASSWORD')
        
        if not self.uptime_kuma_url:
            logger.error("UPTIME_KUMA_URL environment variable is required")
            sys.exit(1)
        
        if not self.uptime_kuma_username:
            logger.error("UPTIME_KUMA_USERNAME environment variable is required")
            sys.exit(1)
        
        if not self.uptime_kuma_password:
            logger.error("UPTIME_KUMA_PASSWORD environment variable is required")
            sys.exit(1)
        
        # Ensure URL ends with /
        if not self.uptime_kuma_url.endswith('/'):
            self.uptime_kuma_url += '/'
        
        logger.info(f"Loaded Uptime Kuma URL: {self.uptime_kuma_url}")
    
    def _setup_session(self):
        """Setup Uptime Kuma API connection with authentication."""
        if self.dry_run:
            logger.info("[DRY RUN] Would connect to Uptime Kuma API")
            return
        
        try:
            # Initialize API connection
            self.api = UptimeKumaApi(self.uptime_kuma_url)
            
            # Login with username and password
            login_result = self.api.login(self.uptime_kuma_username, self.uptime_kuma_password)
            
            if login_result.get('token'):
                logger.info("Successfully connected and authenticated to Uptime Kuma API")
            else:
                logger.error("Failed to authenticate with Uptime Kuma API")
                sys.exit(1)
                
        except Exception as e:
            logger.error(f"Failed to connect to Uptime Kuma API: {e}")
            sys.exit(1)
    
    def get_container_names(self) -> List[str]:
        """Get list of running container names using docker ps."""
        try:
            result = subprocess.run(
                ["docker", "ps", "--format", "{{.Names}}"],
                capture_output=True,
                text=True,
                check=True,
                timeout=30
            )
            
            all_containers = [name.strip() for name in result.stdout.split('\n') if name.strip()]
            
            # Filter containers if pattern is specified
            if self.container_filter:
                filtered_containers = [name for name in all_containers if self.container_filter.match(name)]
                logger.info(f"Filtered {len(all_containers)} containers to {len(filtered_containers)} matching pattern '{self.container_filter.pattern}'")
                return filtered_containers
            
            logger.info(f"Found {len(all_containers)} running containers")
            return all_containers
            
        except subprocess.CalledProcessError as e:
            logger.error(f"Failed to get container names: {e}")
            return []
        except subprocess.TimeoutExpired:
            logger.error("docker ps command timed out")
            return []
        except Exception as e:
            logger.error(f"Error getting container names: {e}")
            return []
    
    def extract_urls_from_container(self, container_name: str) -> List[str]:
        """
        Extract URLs from a container's inspect data.
        
        Args:
            container_name: Name of the container to inspect
            
        Returns:
            List of URLs found in the container
        """
        urls = []
        
        try:
            # Get container inspection data
            result = subprocess.run(
                ["docker", "inspect", container_name],
                capture_output=True,
                text=True,
                check=True,
                timeout=30
            )
            
            inspect_data = json.loads(result.stdout)[0]
            
            # Method 1: Extract from environment variables (WP_HOME)
            env_vars = inspect_data.get('Config', {}).get('Env', [])
            for env_var in env_vars:
                if env_var.startswith('WP_HOME='):
                    wp_home = env_var.split('=', 1)[1]
                    # Clean URL - remove protocol for consistent comparison
                    clean_url = self._clean_url(wp_home)
                    if clean_url:
                        urls.append(clean_url)
                        logger.debug(f"Found WP_HOME URL for {container_name}: {clean_url}")
            
            # Method 2: Extract from Traefik labels
            labels = inspect_data.get('Config', {}).get('Labels', {})
            for label_key, label_value in labels.items():
                if "traefik.http.routers" in label_key and "rule" in label_key:
                    # Extract Host() rules from Traefik labels
                    if "Host(" in label_value:
                        hosts = re.findall(r'Host\(`([^`]+)`\)', label_value)
                        for host in hosts:
                            clean_url = self._clean_url(f"https://{host}")
                            if clean_url:
                                urls.append(clean_url)
                                logger.debug(f"Found Traefik Host for {container_name}: {clean_url}")
            
            # Remove duplicates while preserving order
            unique_urls = []
            for url in urls:
                if url not in unique_urls:
                    unique_urls.append(url)
            
            logger.info(f"Extracted {len(unique_urls)} URLs from container {container_name}: {unique_urls}")
            return unique_urls
            
        except subprocess.CalledProcessError as e:
            logger.error(f"Failed to inspect container {container_name}: {e}")
            return []
        except subprocess.TimeoutExpired:
            logger.error(f"docker inspect timed out for container {container_name}")
            return []
        except (json.JSONDecodeError, KeyError, IndexError) as e:
            logger.error(f"Failed to parse container inspect output for {container_name}: {e}")
            return []
        except Exception as e:
            logger.error(f"Error extracting URLs from container {container_name}: {e}")
            return []
    
    def _clean_url(self, url: str) -> Optional[str]:
        """
        Clean and validate URL.
        
        Args:
            url: Raw URL string
            
        Returns:
            Cleaned URL or None if invalid
        """
        if not url:
            return None
        
        # Remove quotes and whitespace
        url = url.strip().strip('"').strip("'")
        
        # Add protocol if missing
        if not url.startswith(('http://', 'https://')):
            url = f"https://{url}"
        
        try:
            parsed = urlparse(url)
            if not parsed.netloc:
                return None
            
            # Basic domain validation
            domain = parsed.netloc.lower()
            if not re.match(r'^[a-zA-Z0-9.-]+$', domain) or '.' not in domain:
                return None
            
            # Return clean URL
            return f"{parsed.scheme}://{parsed.netloc}"
            
        except Exception:
            return None
    
    def get_existing_monitors(self) -> Dict[str, Any]:
        """
        Get list of existing monitors from Uptime Kuma.
        
        Returns:
            Dictionary mapping URLs to monitor data
        """
        if self.dry_run:
            logger.info("[DRY RUN] Would fetch existing monitors from Uptime Kuma")
            return {}
        
        try:
            # Use the proper API to get monitors
            monitors_data = self.api.get_monitors()
            monitors = {}
            
            # Process monitors data
            for monitor in monitors_data:
                if isinstance(monitor, dict) and 'url' in monitor:
                    clean_url = self._clean_url(monitor['url'])
                    if clean_url:
                        monitors[clean_url] = monitor
            
            logger.info(f"Found {len(monitors)} existing monitors in Uptime Kuma")
            return monitors
            
        except Exception as e:
            logger.error(f"Error fetching existing monitors: {e}")
            return {}
    
    def add_monitor(self, url: str, container_name: str) -> bool:
        """
        Add a new monitor to Uptime Kuma.
        
        Args:
            url: URL to monitor
            container_name: Name of the source container
            
        Returns:
            True if successful, False otherwise
        """
        if self.dry_run:
            logger.info(f"[DRY RUN] Would add monitor for {url} (container: {container_name})")
            return True
        
        try:
            # Use the proper API to add monitor
            result = self.api.add_monitor(
                type=MonitorType.HTTP,
                name=f"{container_name} - {urlparse(url).netloc}",
                url=url,
                method="GET",
                interval=60,  # Check every 60 seconds
                timeout=30,
                maxretries=3,
                upsideDown=False,
                notificationIDList=[],
                ignoreTls=False,
                keyword="",
                description=f"Auto-generated monitor for container {container_name}"
            )
            
            if result.get('msg') == 'Added Successfully.':
                logger.info(f"Successfully added monitor for {url} (container: {container_name})")
                return True
            else:
                logger.error(f"Failed to add monitor for {url}: {result}")
                return False
                
        except Exception as e:
            logger.error(f"Error adding monitor for {url}: {e}")
            return False
    
    def disconnect(self):
        """Disconnect from Uptime Kuma API."""
        if self.api and not self.dry_run:
            try:
                self.api.disconnect()
                logger.info("Disconnected from Uptime Kuma API")
            except Exception as e:
                logger.warning(f"Error disconnecting from API: {e}")
    
    def process_containers(self):
        """Main processing function to handle all containers."""
        logger.info("Starting container processing...")
        
        # Get all container names
        container_names = self.get_container_names()
        if not container_names:
            logger.warning("No containers found to process")
            return
        
        # Get existing monitors
        self.existing_monitors = self.get_existing_monitors()
        
        # Process each container
        processed_urls = set()
        added_count = 0
        skipped_count = 0
        
        for container_name in container_names:
            logger.info(f"Processing container: {container_name}")
            
            # Extract URLs from container
            urls = self.extract_urls_from_container(container_name)
            
            if not urls:
                logger.warning(f"No URLs found for container {container_name}")
                continue
            
            # Process each URL
            for url in urls:
                if url in processed_urls:
                    logger.debug(f"URL {url} already processed, skipping")
                    continue
                
                processed_urls.add(url)
                
                # Check if already monitored
                if url in self.existing_monitors:
                    logger.info(f"URL {url} is already monitored, skipping")
                    skipped_count += 1
                    continue
                
                # Add new monitor
                if self.add_monitor(url, container_name):
                    added_count += 1
                    # Small delay to avoid overwhelming the API
                    if not self.dry_run:
                        time.sleep(0.5)
        
        # Summary
        logger.info(f"Processing complete:")
        logger.info(f"  - Containers processed: {len(container_names)}")
        logger.info(f"  - URLs found: {len(processed_urls)}")
        logger.info(f"  - Monitors added: {added_count}")
        logger.info(f"  - Monitors skipped (already exist): {skipped_count}")


def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description="Manage Uptime Kuma monitors for Docker containers"
    )
    parser.add_argument(
        '--dry-run',
        action='store_true',
        help='Simulate operations without making changes'
    )
    parser.add_argument(
        '--container-filter',
        default='^wp_',
        help='Regex pattern to filter container names (default: "^wp_" for WordPress containers, use "" for all containers)'
    )
    parser.add_argument(
        '--verbose',
        action='store_true',
        help='Enable verbose logging'
    )
    
    args = parser.parse_args()
    
    # Set logging level
    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)
    
    # Create manager and process containers
    manager = UptimeKumaManager(
        dry_run=args.dry_run,
        container_filter=args.container_filter
    )
    
    try:
        manager.process_containers()
    except KeyboardInterrupt:
        logger.info("Processing interrupted by user")
    except Exception as e:
        logger.error(f"Unexpected error: {e}")
        sys.exit(1)
    finally:
        # Always disconnect from API
        manager.disconnect()


if __name__ == "__main__":
    main()
