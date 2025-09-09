#!/usr/bin/env python3

import subprocess
import json
import sys
import os
import argparse
import re
import shlex
from datetime import datetime
from typing import List, Dict, Optional, Tuple
import logging
import glob


logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[logging.StreamHandler()]
)

class WordPressUpdater:
    def __init__(self, container_name: Optional[str] = None, dry_run: bool = False, verbose: bool = False):
        self.container_name = container_name
        self.working_dir = None
        self.wp_containers = []
        self.dry_run = dry_run
        self.is_interactive = sys.stdin.isatty()
        self.verbose = verbose
        if self.verbose:
            logging.getLogger().setLevel(logging.DEBUG)

    def log(self, msg, level=logging.INFO):
        if self.verbose or level >= logging.INFO:
            logging.log(level, msg)

    def get_wp_containers(self) -> List[str]:
        self.log("Getting all Docker containers with names starting with 'wp_'", logging.DEBUG)
        try:
            result = subprocess.run(['docker', 'ps', '--format', '{{.Names}}'],
                                    capture_output=True, text=True, check=True)
            containers = [line.strip() for line in result.stdout.split('\n') if line.strip().startswith('wp_')]
            self.log(f"Found containers: {containers}", logging.DEBUG)
            return containers
        except subprocess.CalledProcessError as e:
            self.log(f"Error getting Docker containers: {e}", logging.ERROR)
            sys.exit(1)

    def get_working_directory(self, container_name: str) -> str:
        self.log(f"Getting working directory for container '{container_name}'", logging.DEBUG)
        """Get the working directory of a Docker container using docker inspect"""
        try:
            cmd = ['docker', 'inspect', container_name]
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)
            inspect_data = json.loads(result.stdout)
            
            # Try to get working directory from labels first
            labels = inspect_data[0].get('Config', {}).get('Labels', {})
            working_dir = labels.get('com.docker.compose.project.working_dir')
            
            if not working_dir:
                # Fallback to container's working directory
                working_dir = inspect_data[0].get('Config', {}).get('WorkingDir')
                
            if not working_dir:
                print(f"⚠️  Could not determine working directory for container '{container_name}'")
                return None
                
            return working_dir
        except (subprocess.CalledProcessError, json.JSONDecodeError, KeyError) as e:
            print(f"❌ Error getting working directory for '{container_name}': {e}")
            return None
    
    def docker_exec(self, container_name: str, command: List[str]) -> subprocess.CompletedProcess:
        self.log(f"Executing in container '{container_name}': {' '.join(command)}", logging.DEBUG)
        """Execute a command in a Docker container as root"""
        cmd = ['docker', 'exec', '-u', '0', container_name] + command
        if self.dry_run:
            print(f"    🔍 DRY RUN: Would execute: {' '.join(cmd)}")
            # For dry run, still need to get actual data for analysis
            return subprocess.run(cmd, capture_output=True, text=True)
        return subprocess.run(cmd, capture_output=True, text=True)
    
    def get_wp_updates(self, container_name: str) -> Dict:
        """Get available WordPress updates using WP CLI"""
        updates = {
            'core': None,
            'plugins': [],
            'themes': []
        }
        
        # Check core updates
        print(f"  🔍 Checking WordPress core updates...")
        result = self.docker_exec(container_name, ['wp', '--allow-root', 'core', 'check-update', '--format=json'])
        if result.returncode == 0 and result.stdout.strip():
            try:
                core_updates = json.loads(result.stdout)
                if core_updates:
                    updates['core'] = core_updates[0]
                    print(f"    📦 Core update available: {core_updates[0]['version']}")
                    if self.dry_run:
                        print(f"    🔍 DRY RUN: Would update WordPress core from current version to {core_updates[0]['version']}")
                else:
                    print(f"    ✅ WordPress core is up to date")
            except json.JSONDecodeError:
                print(f"    ⚠️  Could not parse core update information")
        else:
            print(f"    ✅ WordPress core is up to date")
        
        # Check plugin updates
        print(f"  🔍 Checking plugin updates...")
        result = self.docker_exec(container_name, ['wp', '--allow-root', 'plugin', 'list', '--update=available', '--format=json'])
        if result.returncode == 0 and result.stdout.strip():
            try:
                plugin_updates = json.loads(result.stdout)
                updates['plugins'] = plugin_updates
                if plugin_updates:
                    print(f"    📦 {len(plugin_updates)} plugin(s) need updates:")
                    for i, plugin in enumerate(plugin_updates, 1):
                        print(f"      {i}. {plugin['name']} - {plugin['version']} → {plugin['update_version']}")
                        if self.dry_run:
                            print(f"         🔍 DRY RUN: Would update plugin '{plugin['name']}' from {plugin['version']} to {plugin['update_version']}")
                else:
                    print(f"    ✅ All plugins are up to date")
            except json.JSONDecodeError:
                print(f"    ⚠️  Could not parse plugin update information")
        else:
            print(f"    ✅ All plugins are up to date")
        
        # Check theme updates
        print(f"  🔍 Checking theme updates...")
        result = self.docker_exec(container_name, ['wp', '--allow-root', 'theme', 'list', '--update=available', '--format=json'])
        if result.returncode == 0 and result.stdout.strip():
            try:
                theme_updates = json.loads(result.stdout)
                updates['themes'] = theme_updates
                if theme_updates:
                    print(f"    📦 {len(theme_updates)} theme(s) need updates:")
                    for i, theme in enumerate(theme_updates, 1):
                        print(f"      {i}. {theme['name']} - {theme['version']} → {theme['update_version']}")
                        if self.dry_run:
                            print(f"         🔍 DRY RUN: Would update theme '{theme['name']}' from {theme['version']} to {theme['update_version']}")
                else:
                    print(f"    ✅ All themes are up to date")
            except json.JSONDecodeError:
                print(f"    ⚠️  Could not parse theme update information")
        else:
            print(f"    ✅ All themes are up to date")
        
        return updates
    
    def parse_selection(self, selection: str, max_items: int) -> List[int]:
        """Parse user selection string (e.g., '1,3,5-7' or '1|3|7')"""
        if not selection or selection.lower() in ['none', 'skip']:
            return []
        
        if selection.lower() == 'all':
            return list(range(1, max_items + 1))
        
        indices = []
        # Handle both comma and pipe separators
        parts = re.split(r'[,|]', selection.strip())
        
        for part in parts:
            part = part.strip()
            if '-' in part:
                # Handle ranges like '1-5'
                try:
                    start, end = map(int, part.split('-'))
                    indices.extend(range(start, end + 1))
                except ValueError:
                    print(f"⚠️  Invalid range format: {part}")
            else:
                # Handle single numbers
                try:
                    indices.append(int(part))
                except ValueError:
                    # Might be a slug name
                    indices.append(part)
        
        return indices
    
    def get_site_url(self, container_name: str) -> Optional[str]:
        """Extract WP_HOME or site URL from container env."""
        try:
            cmd = ['docker', 'inspect', container_name]
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)
            inspect_data = json.loads(result.stdout)
            envs = inspect_data[0].get('Config', {}).get('Env', [])
            for env_var in envs:
                if env_var.startswith('WP_HOME='):
                    return env_var.split('=', 1)[1].replace('https://', '').replace('http://', '').strip('/')
        except Exception as e:
            print(f"⚠️  Could not extract site URL: {e}")
        return None

    def backup_site(self, container_name: str, working_dir: str, delete_tarballs_in_container: bool = False) -> bool:
        self.log(f"Starting backup for container '{container_name}' in '{working_dir}'", logging.INFO)
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        site_url = self.get_site_url(container_name) or container_name.replace('wp_', '')
        backup_dir = f"/var/opt/{site_url}/www/backups"
        db_backup_file = f"wp_backup_{container_name}_{timestamp}.sql"

        if self.dry_run:
            self.log(f"  🔍 DRY RUN: Would create backup for '{container_name}'...")
            self.log(f"    🔍 DRY RUN: Would create backup directory: {backup_dir}")
            self.log(f"    🔍 DRY RUN: Would export database to: {backup_dir}/{db_backup_file}")
            self.log(f"    🔍 DRY RUN: Backup would be created successfully")
            return True

        self.log(f"  💾 Creating backup for '{container_name}'...")

        # Ensure backup directory exists on the host
        try:
            os.makedirs(backup_dir, exist_ok=True)
        except Exception as e:
            self.log(f"    ❌ Failed to create backup directory '{backup_dir}': {e}")
            return False

        # Also ensure the directory exists inside the container
        mkdir_cmd = ['docker', 'exec', '-u', '0', container_name, 'mkdir', '-p', backup_dir]
        subprocess.run(mkdir_cmd, capture_output=True)

        # Backup database
        self.log(f"    🗄️  Exporting database...", logging.INFO)
        db_path = f"{backup_dir}/{db_backup_file}"
        result = self.docker_exec(container_name, ['wp', '--allow-root', 'db', 'export', db_path])
        if result.returncode != 0:
            self.log(f"    ❌ Database backup failed: {result.stderr}", logging.ERROR)
            return False

        self.log(f"Backup created: {db_path}", logging.INFO)
        return True

    def update_wordpress_core(self, container_name: str) -> bool:
        """Update WordPress core"""
        if self.dry_run:
            print(f"    🔍 DRY RUN: Would update WordPress core...")
            print(f"    🔍 DRY RUN: Would execute: docker exec -u 0 {container_name} wp --allow-root core update")
            print(f"    🔍 DRY RUN: WordPress core would be updated successfully")
            return True
            
        print(f"    🔄 Updating WordPress core...")
        result = self.docker_exec(container_name, ['wp', '--allow-root', 'core', 'update'])
        if result.returncode == 0:
            print(f"    ✅ WordPress core updated successfully")
            return True
        else:
            print(f"    ❌ WordPress core update failed: {result.stderr}")
            return False
    
    def update_plugins(self, container_name: str, plugins: List, selected_indices: List) -> bool:
        """Update selected plugins"""
        if self.dry_run:
            print(f"    🔍 DRY RUN: Would update selected plugins...")
            for idx in selected_indices:
                if isinstance(idx, int) and 1 <= idx <= len(plugins):
                    plugin = plugins[idx - 1]
                    plugin_name = plugin['name']
                    plugin_title = plugin.get('title', plugin_name)
                    current_version = plugin.get('version', 'unknown')
                    new_version = plugin.get('update_version', 'latest')
                elif isinstance(idx, str):
                    plugin_name = idx
                    plugin_title = idx
                    current_version = 'current'
                    new_version = 'latest'
                else:
                    print(f"    🔍 DRY RUN: Would skip invalid plugin selection: {idx}")
                    continue
                
                print(f"    🔍 DRY RUN: Would update plugin '{plugin_name}' ({plugin_title})")
                print(f"       🔍 DRY RUN: Would execute: docker exec -u 0 {container_name} wp --allow-root plugin update {plugin_name}")
                print(f"       🔍 DRY RUN: Plugin '{plugin_name}' would be updated from {current_version} to {new_version}")
            print(f"    🔍 DRY RUN: All selected plugins would be updated successfully")
            return True
        
        success = True
        for idx in selected_indices:
            if isinstance(idx, int) and 1 <= idx <= len(plugins):
                plugin = plugins[idx - 1]
                plugin_name = plugin['name']
            elif isinstance(idx, str):
                # Assume it's a plugin slug
                plugin_name = idx
            else:
                print(f"    ⚠️  Invalid plugin selection: {idx}")
                continue
            
            print(f"    🔄 Updating plugin '{plugin_name}'...")
            result = self.docker_exec(container_name, ['wp', '--allow-root', 'plugin', 'update', plugin_name])
            if result.returncode == 0:
                print(f"    ✅ Plugin '{plugin_name}' updated successfully")
            else:
                print(f"    ❌ Plugin '{plugin_name}' update failed: {result.stderr}")
                success = False
        
        return success
    
    def update_themes(self, container_name: str, themes: List, selected_indices: List) -> bool:
        """Update selected themes"""
        if self.dry_run:
            print(f"    🔍 DRY RUN: Would update selected themes...")
            for idx in selected_indices:
                if isinstance(idx, int) and 1 <= idx <= len(themes):
                    theme = themes[idx - 1]
                    theme_name = theme['name']
                    theme_title = theme.get('title', theme_name)
                    current_version = theme.get('version', 'unknown')
                    new_version = theme.get('update_version', 'latest')
                elif isinstance(idx, str):
                    theme_name = idx
                    theme_title = idx
                    current_version = 'current'
                    new_version = 'latest'
                else:
                    print(f"    🔍 DRY RUN: Would skip invalid theme selection: {idx}")
                    continue
                
                print(f"    🔍 DRY RUN: Would update theme '{theme_name}' ({theme_title})")
                print(f"       🔍 DRY RUN: Would execute: docker exec -u 0 {container_name} wp --allow-root theme update {theme_name}")
                print(f"       🔍 DRY RUN: Theme '{theme_name}' would be updated from {current_version} to {new_version}")
            print(f"    🔍 DRY RUN: All selected themes would be updated successfully")
            return True
        
        success = True
        for idx in selected_indices:
            if isinstance(idx, int) and 1 <= idx <= len(themes):
                theme = themes[idx - 1]
                theme_name = theme['name']
            elif isinstance(idx, str):
                # Assume it's a theme slug
                theme_name = idx
            else:
                print(f"    ⚠️  Invalid theme selection: {idx}")
                continue
            
            print(f"    🔄 Updating theme '{theme_name}'...")
            result = self.docker_exec(container_name, ['wp', '--allow-root', 'theme', 'update', theme_name])
            if result.returncode == 0:
                print(f"    ✅ Theme '{theme_name}' updated successfully")
            else:
                print(f"    ❌ Theme '{theme_name}' update failed: {result.stderr}")
                success = False
        
        return success
    
    def update_rank_math_elementor_plugins(self, container_name: str, plugins: list) -> bool:
        """
        Update Rank Math and Elementor plugins in the required order if present.
        Order: seo-by-rank-math, seo-by-rank-math-pro, elementor, elementor-pro
        """
        plugin_order = [
            "seo-by-rank-math",
            "seo-by-rank-math-pro",
            "elementor",
            "elementor-pro"
        ]
        found_plugins = [p for p in plugin_order if any(pl['name'] == p for pl in plugins)]
        if not found_plugins:
            return True  # Nothing to do

        print(f"\n🔄 Updating Rank Math and Elementor plugins in required order:")
        success = True
        for plugin_slug in found_plugins:
            print(f"    🔄 Updating '{plugin_slug}'...")
            result = self.docker_exec(container_name, ['wp', '--allow-root', 'plugin', 'update', plugin_slug])
            if result.returncode == 0:
                print(f"    ✅ Plugin '{plugin_slug}' updated successfully")
            else:
                print(f"    ❌ Plugin '{plugin_slug}' update failed: {result.stderr}")
                success = False
        return success

    def print_dry_run_summary(self, selected_container: str, updates: Dict, 
                            update_core: bool = None, update_plugins: str = None, 
                            update_themes: str = None, backup: bool = True):
        """Print a comprehensive summary of what would happen in dry run mode"""
        if not self.dry_run:
            return
            
        print(f"\n" + "="*80)
        print(f"🔍 DRY RUN SUMMARY - No changes will be made")
        print(f"="*80)
        print(f"Container: {selected_container}")
        print(f"Working Directory: {self.working_dir}")
        print(f"Timestamp: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        
        action_count = 0
        
        # Backup actions
        if backup:
            action_count += 1
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            print(f"\n{action_count}. BACKUP CREATION:")
            print(f"   📁 Create backup directory: {self.working_dir}/backups")
            print(f"   🗄️  Export database: wp_backup_{selected_container}_{timestamp}.sql")
            print(f"   📦 Create tarball: wp_backup_{selected_container}_{timestamp}.tar.gz")
        
        # Core update actions
        if update_core is not None:
            if update_core and updates['core']:
                action_count += 1
                core_info = updates['core']
                print(f"\n{action_count}. WORDPRESS CORE UPDATE:")
                print(f"   🎯 Target: WordPress Core")
                print(f"   📦 New Version: {core_info['version']}")
                print(f"   💻 Command: docker exec -u 0 {selected_container} wp --allow-root core update")
            elif update_core and not updates['core']:
                print(f"\n❌ WORDPRESS CORE: No updates available")
        
        # Plugin update actions
        if update_plugins:
            if updates['plugins']:
                selected_plugins = self.parse_selection(update_plugins, len(updates['plugins']))
                if selected_plugins:
                    action_count += 1
                    print(f"\n{action_count}. PLUGIN UPDATES:")
                    for idx in selected_plugins:
                        if isinstance(idx, int) and 1 <= idx <= len(updates['plugins']):
                            plugin = updates['plugins'][idx - 1]
                            print(f"   🔌 Plugin: {plugin['name']}")
                            print(f"      📦 Version: {plugin['version']} → {plugin['update_version']}")
                            print(f"      💻 Command: docker exec -u 0 {selected_container} wp --allow-root plugin update {plugin['name']}")
                        elif isinstance(idx, str):
                            print(f"   🔌 Plugin: {idx} (by slug)")
                            print(f"      💻 Command: docker exec -u 0 {selected_container} wp --allow-root plugin update {idx}")
            else:
                print(f"\n❌ PLUGINS: No updates available")
        
        # Theme update actions
        if update_themes:
            if updates['themes']:
                selected_themes = self.parse_selection(update_themes, len(updates['themes']))
                if selected_themes:
                    action_count += 1
                    print(f"\n{action_count}. THEME UPDATES:")
                    for idx in selected_themes:
                        if isinstance(idx, int) and 1 <= idx <= len(updates['themes']):
                            theme = updates['themes'][idx - 1]
                            print(f"   🎨 Theme: {theme['name']}")
                            print(f"      📦 Version: {theme['version']} → {theme['update_version']}")
                            print(f"      💻 Command: docker exec -u 0 {selected_container} wp --allow-root theme update {theme['name']}")
                        elif isinstance(idx, str):
                            print(f"   🎨 Theme: {idx} (by slug)")
                            print(f"      💻 Command: docker exec -u 0 {selected_container} wp --allow-root theme update {idx}")
            else:
                print(f"\n❌ THEMES: No updates available")
        
        if action_count == 0:
            print(f"\n✅ No actions would be performed - everything is up to date")
        
        print(f"\n" + "="*80)
        print(f"🔍 End of dry run summary - {action_count} action(s) would be performed")
        print(f"💡 Run without --dry-run to execute these changes")
        print(f"="*80)
    
    def safe_input(self, prompt: str, default: str = "") -> str:
        """Safely get user input, handling non-interactive environments"""
        if not self.is_interactive:
            print(f"{prompt}[non-interactive, using default: {default}]")
            return default
        
        try:
            return input(prompt)
        except (EOFError, KeyboardInterrupt):
            print(f"\n[interrupted, using default: {default}]")
            return default
    
    def run_interactive(self, skip_rank_math_elementor_update=False, restart_docker=False):
        """Run the updater in interactive mode"""
        if self.dry_run:
            print("🔍 DRY RUN MODE: No changes will be made - showing what would happen")
        
        # Get all WordPress containers
        self.wp_containers = self.get_wp_containers()
        
        if not self.wp_containers:
            print("❌ No WordPress Docker containers found with 'wp_' prefix.")
            sys.exit(1)
        
        # Select container
        selected_container = None
        if self.container_name:
            if self.container_name not in self.wp_containers:
                print(f"❌ Container '{self.container_name}' not found.")
                sys.exit(1)
            selected_container = self.container_name
        else:
            # Check if we can run interactively for container selection
            if not self.is_interactive:
                print("❌ Container selection requires interactive mode or --container-name parameter")
                print("Available containers:")
                for i, container in enumerate(self.wp_containers, 1):
                    print(f"  {i}. {container}")
                print("Use --container-name <name> to specify a container")
                sys.exit(1)
            
            print(f"📦 Found WordPress containers:")
            for i, container in enumerate(self.wp_containers, 1):
                print(f"  {i}. {container}")
            
            while True:
                try:
                    prompt_text = "\nSelect container number: "
                    choice = self.safe_input(prompt_text, "1")
                    if not choice:  # Handle empty input in non-interactive mode
                        choice = "1"
                    idx = int(choice) - 1
                    if 0 <= idx < len(self.wp_containers):
                        selected_container = self.wp_containers[idx]
                        break
                    else:
                        print("Please enter a valid number.")
                except (ValueError, IndexError):
                    print("Please enter a valid number.")
                    if not self.is_interactive:
                        print("Using first container as default")
                        selected_container = self.wp_containers[0]
                        break
        
        print(f"\n🎯 Processing container: '{selected_container}'")
        
        # Get working directory
        self.working_dir = self.get_working_directory(selected_container)
        if not self.working_dir:
            sys.exit(1)
        
        print(f"📁 Working directory: {self.working_dir}")
        
        # Check for updates
        print(f"\n🔍 Checking for available updates...")
        updates = self.get_wp_updates(selected_container)

        # --- NEW: Update Rank Math and Elementor plugins first ---
        if updates['plugins'] and not skip_rank_math_elementor_update:
            self.update_rank_math_elementor_plugins(selected_container, updates['plugins'])
        # --- END NEW ---

        # Check if any updates are available
        has_updates = (updates['core'] is not None or 
                      len(updates['plugins']) > 0 or 
                      len(updates['themes']) > 0)
        
        if not has_updates:
            print(f"\n✅ No updates available for '{selected_container}'")
            if self.dry_run:
                print(f"🔍 DRY RUN: No actions would be performed")
            return
        
        # Variables to track user choices for dry run summary
        will_backup = True
        will_update_core = False
        will_update_plugins = None
        will_update_themes = None
        
        # Ask for confirmation to proceed
        if self.dry_run:
            print(f"\n🔍 DRY RUN: Simulating user confirmation for backup and updates...")
            proceed = True
        elif not self.is_interactive:
            print(f"\n🔍 Non-interactive mode: Proceeding with updates (use --non-interactive for full automation)")
            proceed = True
        else:
            proceed_input = self.safe_input("\n❓ Do you want to create a backup and proceed with updates? (y/N): ", "n")
            proceed = proceed_input.lower() in ['y', 'yes']
        
        if not proceed:
            print("❌ Update cancelled by user.")
            if self.dry_run:
                print("🔍 DRY RUN: No actions would be performed")
            return
        
        # Create backup
        print(f"\n💾 Creating backup...")
        if not self.backup_site(selected_container, self.working_dir):
            if not self.dry_run:
                print("❌ Backup failed. Aborting updates.")
                return
        
        # Handle core updates
        if updates['core']:
            if self.dry_run:
                print(f"\n🔍 DRY RUN: Simulating core update prompt...")
                will_update_core = True
            elif not self.is_interactive:
                print(f"\n🔍 Non-interactive mode: Skipping core update (use --update-core flag)")
                will_update_core = False
            else:
                core_input = self.safe_input(f"\n❓ Update WordPress core to {updates['core']['version']}? (y/N): ", "n")
                will_update_core = core_input.lower() in ['y', 'yes']
            
            if will_update_core:
                self.update_wordpress_core(selected_container)
        
        # Handle plugin updates
        if updates['plugins']:
            if self.dry_run:
                print(f"\n🔍 DRY RUN: Simulating plugin update selection...")
                will_update_plugins = "all"  # Simulate selecting all for dry run
            elif not self.is_interactive:
                print(f"\n🔍 Non-interactive mode: Skipping plugin updates (use --update-plugins flag)")
                will_update_plugins = None
            else:
                will_update_plugins = self.safe_input("\n❓ Which plugins to update? (all/none/1,3,5/1-5/plugin-slug): ", "none")
            
            if will_update_plugins and will_update_plugins.lower() not in ['none', 'skip']:
                selected_plugins = self.parse_selection(will_update_plugins, len(updates['plugins']))
                if selected_plugins:
                    print(f"\n🔄 Updating selected plugins...")
                    self.update_plugins(selected_container, updates['plugins'], selected_plugins)
        
        # Handle theme updates
        if updates['themes']:
            if self.dry_run:
                print(f"\n🔍 DRY RUN: Simulating theme update selection...")
                will_update_themes = "all"  # Simulate selecting all for dry run
            elif not self.is_interactive:
                print(f"\n🔍 Non-interactive mode: Skipping theme updates (use --update-themes flag)")
                will_update_themes = None
            else:
                will_update_themes = self.safe_input("\n❓ Which themes to update? (all/none/1,3,5/1-5/theme-slug): ", "none")
            
            if will_update_themes and will_update_themes.lower() not in ['none', 'skip']:
                selected_themes = self.parse_selection(will_update_themes, len(updates['themes']))
                if selected_themes:
                    print(f"\n🔄 Updating selected themes...")
                    self.update_themes(selected_container, updates['themes'], selected_themes)
        
        if self.dry_run:
            self.print_dry_run_summary(selected_container, updates, will_update_core, 
                                     will_update_plugins, will_update_themes, will_backup)
        else:
            print(f"\n✅ Update process completed for '{selected_container}'")
            if restart_docker:
                self.restart_docker_compose(self.working_dir)
            self.mirror_wp_assets(selected_container)

    def run_non_interactive(self, update_core: bool, update_plugins: str, update_themes: str, 
                          backup: bool = True, skip_rank_math_elementor_update=False, restart_docker=False, mirror_assets=False):
        """Run the updater in non-interactive mode"""
        if self.dry_run:
            print("🔍 DRY RUN MODE: No changes will be made - showing what would happen")
        
        # Get container
        if self.container_name:
            if self.container_name not in self.get_wp_containers():
                print(f"❌ Container '{self.container_name}' not found.")
                sys.exit(1)
            selected_container = self.container_name
        else:
            print(f"❌ Container name is required for non-interactive mode.")
            sys.exit(1)
        
        mode_text = "(non-interactive dry run mode)" if self.dry_run else "(non-interactive mode)"
        print(f"🎯 Processing container: '{selected_container}' {mode_text}")
        
        # Get working directory
        self.working_dir = self.get_working_directory(selected_container)
        if not self.working_dir:
            sys.exit(1)
        
        print(f"📁 Working directory: {self.working_dir}")
        
        # Check for updates
        print(f"🔍 Checking for available updates...")
        updates = self.get_wp_updates(selected_container)

        # --- NEW: Update Rank Math and Elementor plugins first ---
        if updates['plugins'] and not skip_rank_math_elementor_update:
            self.update_rank_math_elementor_plugins(selected_container, updates['plugins'])
        # --- END NEW ---

        # Create backup if requested
        if backup:
            print(f"💾 Creating backup...")
            if not self.backup_site(selected_container, self.working_dir):
                if not self.dry_run:
                    print("❌ Backup failed. Aborting updates.")
                    sys.exit(1)
        
        # Update core
        if update_core and updates['core']:
            print(f"🔄 Updating WordPress core...")
            self.update_wordpress_core(selected_container)
        elif update_core and not updates['core']:
            print(f"✅ WordPress core is already up to date")
        
        # Update plugins
        if update_plugins and updates['plugins']:
            print(f"🔄 Updating plugins...")
            selected_plugins = self.parse_selection(update_plugins, len(updates['plugins']))
            if selected_plugins:
                self.update_plugins(selected_container, updates['plugins'], selected_plugins)
        elif update_plugins and not updates['plugins']:
            print(f"✅ All plugins are already up to date")
        
        # Update themes
        if update_themes and updates['themes']:
            print(f"🔄 Updating themes...")
            selected_themes = self.parse_selection(update_themes, len(updates['themes']))
            if selected_themes:
                self.update_themes(selected_container, updates['themes'], selected_themes)
        elif update_themes and not updates['themes']:
            print(f"✅ All themes are already up to date")
        
        if self.dry_run:
            self.print_dry_run_summary(selected_container, updates, update_core, 
                                     update_plugins, update_themes, backup)
        else:
            print(f"✅ Non-interactive update process completed for '{selected_container}'")
            if restart_docker:
                self.restart_docker_compose(self.working_dir)
            if mirror_assets:
                self.mirror_wp_assets(selected_container)

    def restart_docker_compose(self, working_dir: str):
        """Restart docker-compose stack."""
        print(f"🔄 Restarting docker-compose stack in '{working_dir}'...")
        try:
            # Change to the working directory
            os.chdir(working_dir)
            # Restart the stack
            result = subprocess.run(['docker-compose', 'down'], capture_output=True, text=True)
            if result.returncode != 0:
                print(f"  ❌ Error stopping containers: {result.stderr}")
            result = subprocess.run(['docker-compose', 'up', '-d'], capture_output=True, text=True)
            if result.returncode != 0:
                print(f"  ❌ Error starting containers: {result.stderr}")
            print(f"  ✅ Docker-compose stack restarted successfully")
        except Exception as e:
            print(f"  ❌ Error restarting docker-compose: {e}")
        finally:
            # Change back to the original directory
            os.chdir(os.path.dirname(os.path.abspath(__file__)))

    def mirror_wp_assets(self, container_name: str):
        """
        Mirrors plugins and themes from a Docker container to the host.
        This is a Python implementation of the mirror-wp-assets.sh script.
        """
        print("\n" + "-"*50)
        print(f"🔗 Mirroring WP assets for container: '{container_name}'")

        if not self.working_dir:
            self.working_dir = self.get_working_directory(container_name)
        
        if not self.working_dir:
            self.log(f"Could not determine working directory for '{container_name}'. Skipping asset mirroring.", logging.ERROR)
            return

        self.log(f"Found working directory: {self.working_dir}", logging.INFO)

        host_content_dir = os.path.join(self.working_dir, 'www', 'wp-content')
        container_content_dir = '/var/www/html/wp-content'

        # Define the subdirectories to mirror
        subdirs = [
            'plugins',
            'themes',
            'uploads'
        ]

        # Mirror each subdirectory
        for subdir in subdirs:
            host_dir = os.path.join(host_content_dir, subdir)
            container_dir = os.path.join(container_content_dir, subdir)

            # Create the host directory if it doesn't exist
            os.makedirs(host_dir, exist_ok=True)

            # Rsync options:
            # -a: archive mode (preserves permissions, timestamps, etc.)
            # -u: skip files that are newer on the receiver
            # --delete: delete files in the destination that are not present in the source
            rsync_cmd = [
                'docker', 'run', '--rm',
                '-v', f"{host_dir}:/mnt/host_dir",
                '-v', f"{container_name}:{container_dir}",
                'alpine', 'sh', '-c',
                f"apk add --no-cache rsync && rsync -au --delete /mnt/host_dir/ /{subdir}/"
            ]

            print(f"  📦 Mirroring {subdir}...")
            result = subprocess.run(rsync_cmd, capture_output=True, text=True)
            if result.returncode == 0:
                print(f"    ✅ {subdir} mirrored successfully")
            else:
                print(f"    ❌ Error mirroring {subdir}: {result.stderr}")

        print(f"🔗 WP assets mirroring completed for container: '{container_name}'")

def parse_container_names_arg(arg) -> list:
    """Parse --container-names argument from file, pipebar, or stdin, supporting both | and \\n delimiters."""
    containers = []
    if arg == "-":
        # Read from stdin, split on both | and \n
        input_text = sys.stdin.read()
        containers = [c.strip() for c in re.split(r'[|\n\r]+', input_text) if c.strip()]
    elif os.path.isfile(arg):
        # Read from file, split on both | and \n
        with open(arg, "r") as f:
            file_text = f.read()
            containers = [c.strip() for c in re.split(r'[|\n\r]+', file_text) if c.strip()]
    else:
        # Assume pipebar-delimited string
        containers = [c.strip() for c in arg.strip().split('|') if c.strip()]
    return containers
	
def main():
    parser = argparse.ArgumentParser(description='WordPress Docker Container Updater')
    parser.add_argument('--container-name', '-c', help='Target specific container name')
    parser.add_argument('--container-names', help='Multiple containers: file, pipebar string, or "-" for stdin')
    parser.add_argument('--all-containers', action='store_true', help='Update all wp_ containers')
    parser.add_argument('--non-interactive', '-n', action='store_true', 
                       help='Run in non-interactive mode')
    parser.add_argument('--update-core', action='store_true', 
                       help='Update WordPress core (non-interactive mode)')
    parser.add_argument('--update-plugins', '-p', 
                       help='Update plugins: all, none, 1,3,5, 1-5, or plugin-slug')
    parser.add_argument('--update-themes', '-t', 
                       help='Update themes: all, none, 1,3,5, 1-5, or theme-slug')
    parser.add_argument('--no-backup', action='store_true', 
                       help='Skip backup creation (non-interactive mode)')
    parser.add_argument('--dry-run', action='store_true',
                       help='Show what would be done without making any changes')
    parser.add_argument('--restart-docker', action='store_true',
                       help='Restart the docker-compose stack after updates are complete.')
    parser.add_argument('--mirror-wp-assets', action='store_true',
                       help='Mirror plugins and themes from container to host after updates.')
    parser.add_argument('--verbose', '-v', action='store_true', help='Increase output verbosity')
    parser.add_argument('--delete-tarballs-in-container', action='store_true',
                       help='Delete any existing tarballs in the container directory before backup')
    parser.add_argument('--skip-backups', action='store_true',
                        help='Skip all backup creation steps')
    parser.add_argument('--skip-rank-math-elementor-update', action='store_true',
                        help='Skip updates for Rank Math and Elementor plugins')

    args = parser.parse_args()
    
    # Validate non-interactive mode requirements
    if args.non_interactive and not args.dry_run and not args.all_containers:
        if not args.container_name:
            print(f"❌ --container-name is required for non-interactive mode")
            sys.exit(1)
        if not any([args.update_core, args.update_plugins, args.update_themes]):
            print("❌ At least one update option must be specified for non-interactive mode")
            sys.exit(1)

    # For dry run without explicit non-interactive flag, suggest using proper flags
    if args.dry_run and not args.non_interactive and not sys.stdin.isatty():
        print("🔍 Detected non-interactive environment with --dry-run")
        if not args.container_name and not args.all_containers:
            print("💡 Tip: Use --container-name or --all-containers for non-interactive dry runs")
        if not any([args.update_core, args.update_plugins, args.update_themes]):
            print("💡 Tip: Use --update-core, --update-plugins, and/or --update-themes to specify what to update")

    # Handle --all-containers
    if args.all_containers:
        updater = WordPressUpdater(dry_run=args.dry_run)
        containers = updater.get_wp_containers()
        if not containers:
            print("❌ No WordPress Docker containers found with 'wp_' prefix.")
            sys.exit(1)
        for container in containers:
            print(f"\n{'='*80}\nProcessing container: {container}\n{'='*80}")
            updater.container_name = container
            updater.working_dir = None  # Reset working dir for each container
            if args.non_interactive:
                updater.run_non_interactive(
                    update_core=args.update_core,
                    update_plugins=args.update_plugins,
                    update_themes=args.update_themes,
                    backup=not (args.no_backup or args.skip_backups),
                    skip_rank_math_elementor_update=args.skip_rank_math_elementor_update
                )
            else:
                updater.run_interactive(skip_rank_math_elementor_update=args.skip_rank_math_elementor_update)
        print("\n✅ All containers processed.")
        sys.exit(0)

    # Handle --container-names
    if args.container_names:
        containers = parse_container_names_arg(args.container_names)
        if not containers:
            print("❌ No containers found from --container-names input.")
            sys.exit(1)
        updater = WordPressUpdater(dry_run=args.dry_run)
        for container in containers:
            print(f"\n{'='*80}\nProcessing container: {container}\n{'='*80}")
            updater.container_name = container
            updater.working_dir = None  # Reset working dir for each container
            if args.non_interactive:
                updater.run_non_interactive(
                    update_core=args.update_core,
                    update_plugins=args.update_plugins,
                    update_themes=args.update_themes,
                    backup=not (args.no_backup or args.skip_backups),
                    skip_rank_math_elementor_update=args.skip_rank_math_elementor_update
                )
            else:
                updater.run_interactive(skip_rank_math_elementor_update=args.skip_rank_math_elementor_update)
        print("\n✅ All specified containers processed.")
        sys.exit(0)

    # Single container logic
    updater = WordPressUpdater(args.container_name, args.dry_run, verbose=args.verbose)
    if args.non_interactive:
        updater.run_non_interactive(
            update_core=args.update_core,
            update_plugins=args.update_plugins,
            update_themes=args.update_themes,
            backup=not (args.no_backup or args.skip_backups),
            skip_rank_math_elementor_update=args.skip_rank_math_elementor_update
        )
    else:
        updater.run_interactive(skip_rank_math_elementor_update=args.skip_rank_math_elementor_update)

if __name__ == "__main__":
    main()