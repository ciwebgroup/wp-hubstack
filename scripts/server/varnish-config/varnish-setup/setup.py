#!/usr/bin/env python3
"""
Varnish Cache Setup Script
==========================
Interactive script to configure Varnish Cache for Traefik + WordPress.

This script will:
1. Detect existing configuration
2. Create Varnish VCL configuration
3. Configure Varnish Docker service
4. Set up Traefik routing
5. Test the configuration

Usage:
    python3 setup.py [options]

Options:
    --services-dir PATH     Path to services directory (default: /var/opt/services)
    --non-interactive       Run without prompts (use defaults/environment vars)
    --dry-run               Show what would be done without making changes
"""

import os
import sys
import json
import shutil
import argparse
import subprocess
from pathlib import Path
from typing import List, Dict, Optional, Tuple
from datetime import datetime


# =============================================================================
# ANSI COLOR CODES
# =============================================================================
class Colors:
    HEADER = '\033[95m'
    BLUE = '\033[94m'
    CYAN = '\033[96m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    RED = '\033[91m'
    BOLD = '\033[1m'
    DIM = '\033[2m'
    END = '\033[0m'


def colorize(text: str, color: str) -> str:
    return f"{color}{text}{Colors.END}"


# =============================================================================
# OUTPUT HELPERS
# =============================================================================
def print_header(text: str):
    width = 70
    print(f"\n{Colors.CYAN}{'═' * width}{Colors.END}")
    print(f"{Colors.BOLD}{Colors.CYAN}{text.center(width)}{Colors.END}")
    print(f"{Colors.CYAN}{'═' * width}{Colors.END}\n")


def print_section(text: str):
    print(f"\n{Colors.BLUE}{'─' * 50}{Colors.END}")
    print(f"{Colors.BOLD}{Colors.BLUE}{text}{Colors.END}")
    print(f"{Colors.BLUE}{'─' * 50}{Colors.END}\n")


def print_success(text: str):
    print(f"  {Colors.GREEN}✓{Colors.END} {text}")


def print_warning(text: str):
    print(f"  {Colors.YELLOW}⚠{Colors.END} {text}")


def print_error(text: str):
    print(f"  {Colors.RED}✗{Colors.END} {text}")


def print_info(text: str):
    print(f"  {Colors.CYAN}ℹ{Colors.END} {text}")


def print_step(step: int, total: int, text: str):
    print(f"\n{Colors.BLUE}[{step}/{total}]{Colors.END} {Colors.BOLD}{text}{Colors.END}")


def prompt(question: str, default: str = "") -> str:
    """Prompt user for input with optional default"""
    if default:
        result = input(f"  {question} [{Colors.DIM}{default}{Colors.END}]: ").strip()
        return result if result else default
    else:
        return input(f"  {question}: ").strip()


def confirm(question: str, default: bool = True) -> bool:
    """Prompt user for yes/no confirmation"""
    suffix = "[Y/n]" if default else "[y/N]"
    result = input(f"  {question} {suffix}: ").strip().lower()
    if not result:
        return default
    return result in ('y', 'yes')


# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================
def run_command(cmd: str, timeout: int = 30) -> Tuple[int, str, str]:
    """Run a shell command and return exit code, stdout, stderr"""
    try:
        result = subprocess.run(
            cmd,
            shell=True,
            capture_output=True,
            text=True,
            timeout=timeout
        )
        return result.returncode, result.stdout.strip(), result.stderr.strip()
    except subprocess.TimeoutExpired:
        return -1, "", "Command timed out"
    except Exception as e:
        return -1, "", str(e)


def docker_available() -> bool:
    """Check if Docker is available"""
    code, _, _ = run_command("docker ps -q")
    return code == 0


def get_wordpress_containers() -> List[Dict]:
    """Get list of WordPress containers"""
    code, stdout, _ = run_command(
        "docker ps --filter 'name=wp_' --format '{{json .}}'"
    )
    
    containers = []
    if code == 0 and stdout:
        for line in stdout.split('\n'):
            if line.strip():
                try:
                    data = json.loads(line)
                    containers.append({
                        'name': data.get('Names', ''),
                        'image': data.get('Image', ''),
                        'status': data.get('Status', ''),
                        'networks': data.get('Networks', '').split(',')
                    })
                except json.JSONDecodeError:
                    pass
    
    return containers


def get_container_labels(container_name: str) -> Dict:
    """Get labels from a container"""
    code, stdout, _ = run_command(
        f"docker inspect {container_name} --format '{{{{json .Config.Labels}}}}'"
    )
    
    if code == 0 and stdout:
        try:
            return json.loads(stdout)
        except json.JSONDecodeError:
            pass
    
    return {}


def extract_hostname_from_labels(labels: Dict) -> Optional[str]:
    """Extract hostname from Traefik labels"""
    for key, value in labels.items():
        if 'rule' in key.lower() and 'host' in value.lower():
            # Extract Host(`example.com`)
            import re
            match = re.search(r'Host\(`([^`]+)`\)', value)
            if match:
                return match.group(1)
    return None


def file_exists(path: str) -> bool:
    return Path(path).exists()


def ensure_dir(path: str):
    Path(path).mkdir(parents=True, exist_ok=True)


def write_file(path: str, content: str, dry_run: bool = False):
    """Write content to file"""
    if dry_run:
        print_info(f"Would write to: {path}")
        return
    
    ensure_dir(str(Path(path).parent))
    with open(path, 'w') as f:
        f.write(content)
    print_success(f"Created: {path}")


def backup_file(path: str, dry_run: bool = False) -> Optional[str]:
    """Create a backup of a file"""
    if not file_exists(path):
        return None
    
    backup_path = f"{path}.backup.{datetime.now().strftime('%Y%m%d_%H%M%S')}"
    
    if dry_run:
        print_info(f"Would backup: {path} → {backup_path}")
        return backup_path
    
    shutil.copy2(path, backup_path)
    print_info(f"Backed up: {path} → {backup_path}")
    return backup_path


# =============================================================================
# TEMPLATE GENERATORS
# =============================================================================
def generate_vcl_backend(name: str, container_name: str) -> str:
    """Generate VCL backend definition"""
    return f'''backend {name} {{
    .host = "{container_name}";
    .port = "80";
    .connect_timeout = 5s;
    .first_byte_timeout = 30s;
    .between_bytes_timeout = 10s;
    
    .probe = {{
        .request =
            "HEAD / HTTP/1.1"
            "Host: localhost"
            "Connection: close";
        .timeout = 3s;
        .interval = 15s;
        .window = 5;
        .threshold = 3;
        .expected_response = 301;
    }}
}}
'''


def generate_vcl_routing(sites: List[Dict]) -> str:
    """Generate VCL routing rules"""
    rules = []
    for i, site in enumerate(sites):
        hostname = site['hostname'].replace('.', r'\.')
        backend = site['backend_name']
        
        if i == 0:
            rules.append(f'''    if (req.http.host ~ "{hostname}") {{
        set req.backend_hint = {backend};
    }}''')
        else:
            rules.append(f'''    else if (req.http.host ~ "{hostname}") {{
        set req.backend_hint = {backend};
    }}''')
    
    # Add default
    if sites:
        rules.append(f'''    else {{
        set req.backend_hint = {sites[0]['backend_name']};
    }}''')
    
    return '\n'.join(rules)


def generate_vcl_config(sites: List[Dict]) -> str:
    """Generate complete VCL configuration"""
    
    # Generate backends
    backends = '\n'.join([
        generate_vcl_backend(site['backend_name'], site['container_name'])
        for site in sites
    ])
    
    # Generate director backends
    director_backends = '\n    '.join([
        f"wordpress.add_backend({site['backend_name']});"
        for site in sites
    ])
    
    # Generate routing
    routing = generate_vcl_routing(sites)
    
    return f'''vcl 4.1;

import std;
import directors;

# =============================================================================
# BACKEND DEFINITIONS
# =============================================================================
{backends}

# ACL for purge/admin requests
acl purge {{
    "localhost";
    "127.0.0.1";
    "172.16.0.0"/12;
    "10.0.0.0"/8;
}}

# =============================================================================
# INITIALIZATION
# =============================================================================
sub vcl_init {{
    new wordpress = directors.round_robin();
    {director_backends}
}}

# =============================================================================
# REQUEST HANDLING
# =============================================================================
sub vcl_recv {{
    # Route to correct backend based on Host header
{routing}
    
    # Ensure X-Forwarded-Proto is set to https (Traefik terminates SSL)
    if (!req.http.X-Forwarded-Proto) {{
        set req.http.X-Forwarded-Proto = "https";
    }}
    
    # Handle purge requests
    if (req.method == "PURGE") {{
        if (!client.ip ~ purge) {{
            return (synth(405, "Method not allowed"));
        }}
        return (purge);
    }}
    
    # Handle BAN requests
    if (req.method == "BAN") {{
        if (!client.ip ~ purge) {{
            return (synth(405, "Method not allowed"));
        }}
        ban("req.http.host == " + req.http.host + " && req.url ~ " + req.url);
        return (synth(200, "Banned"));
    }}
    
    # Normalize host header
    if (req.http.host) {{
        set req.http.host = regsub(req.http.host, "^www\\.", "");
        set req.http.host = regsub(req.http.host, ":[0-9]+", "");
    }}
    
    # WordPress: Never cache admin, login, cron
    if (req.url ~ "wp-admin|wp-login|wp-cron|xmlrpc\\.php|preview=true") {{
        return (pass);
    }}
    
    # Never cache POST requests
    if (req.method == "POST") {{
        return (pass);
    }}
    
    # Never cache if logged in
    if (req.http.Cookie ~ "wordpress_logged_in|wordpress_sec_|wp-postpass_|comment_author_") {{
        return (pass);
    }}
    
    # Don't cache cart/checkout (WooCommerce)
    if (req.url ~ "cart|checkout|my-account|add-to-cart|logout") {{
        return (pass);
    }}
    
    # Static files - always cache
    if (req.url ~ "\\.(css|js|jpg|jpeg|png|gif|ico|svg|woff|woff2|ttf|eot|webp|avif|mp4|webm|pdf)(\\?.*)?$") {{
        unset req.http.Cookie;
        return (hash);
    }}
    
    # Remove tracking cookies
    set req.http.Cookie = regsuball(req.http.Cookie, "utm[a-z_]+=[^;]+(; )?", "");
    set req.http.Cookie = regsuball(req.http.Cookie, "_ga[^=]*=[^;]+(; )?", "");
    set req.http.Cookie = regsuball(req.http.Cookie, "_gid=[^;]+(; )?", "");
    set req.http.Cookie = regsuball(req.http.Cookie, "_fbp=[^;]+(; )?", "");
    
    # Clean up empty cookies
    if (req.http.Cookie == "" || req.http.Cookie ~ "^\\s*$") {{
        unset req.http.Cookie;
    }}
    
    return (hash);
}}

# =============================================================================
# BACKEND RESPONSE HANDLING
# =============================================================================
sub vcl_backend_response {{
    # Grace: Serve stale while refreshing (24 hours)
    set beresp.grace = 24h;
    
    # Keep: Serve stale when backend DOWN (7 days) - STALE-IF-ERROR
    set beresp.keep = 7d;
    
    # Don't cache 5xx errors
    if (beresp.status >= 500 && beresp.status < 600) {{
        if (bereq.is_bgfetch) {{
            return (abandon);
        }}
        set beresp.ttl = 0s;
        set beresp.uncacheable = true;
        return (deliver);
    }}
    
    # Handle redirects
    if (beresp.status == 301 || beresp.status == 302) {{
        set beresp.ttl = 1h;
        set beresp.grace = 1h;
        return (deliver);
    }}
    
    # Override WordPress max-age=0
    if (beresp.http.Cache-Control ~ "max-age=0" || !beresp.http.Cache-Control) {{
        if (beresp.http.Cache-Control !~ "no-store|private") {{
            set beresp.ttl = 5m;
        }}
    }}
    
    # Static files: cache longer
    if (bereq.url ~ "\\.(css|js|jpg|jpeg|png|gif|ico|svg|woff|woff2|webp|avif)(\\?.*)?$") {{
        unset beresp.http.Set-Cookie;
        set beresp.ttl = 7d;
        set beresp.grace = 1d;
    }}
    
    unset beresp.http.Server;
    unset beresp.http.X-Powered-By;
    
    return (deliver);
}}

# =============================================================================
# CACHE HIT HANDLING
# =============================================================================
sub vcl_hit {{
    if (obj.ttl >= 0s) {{
        return (deliver);
    }}
    
    if (obj.ttl + obj.grace > 0s) {{
        return (deliver);
    }}
    
    if (obj.ttl + obj.grace + obj.keep > 0s) {{
        if (!std.healthy(req.backend_hint)) {{
            set req.http.X-Varnish-Grace = "stale-if-error";
            return (deliver);
        }}
    }}
    
    return (restart);
}}

# =============================================================================
# RESPONSE DELIVERY
# =============================================================================
sub vcl_deliver {{
    if (obj.hits > 0) {{
        set resp.http.X-Cache = "HIT";
        set resp.http.X-Cache-Hits = obj.hits;
    }} else {{
        set resp.http.X-Cache = "MISS";
    }}
    
    if (req.http.X-Varnish-Grace) {{
        set resp.http.X-Cache = "STALE-IF-ERROR";
    }} else if (obj.ttl < 0s) {{
        set resp.http.X-Cache = "STALE-GRACE";
    }}
    
    set resp.http.X-Cache-Backend = "Varnish-7.6";
    
    unset resp.http.Via;
    unset resp.http.X-Varnish;
    
    return (deliver);
}}

# =============================================================================
# BACKEND ERROR
# =============================================================================
sub vcl_backend_error {{
    set beresp.http.Content-Type = "text/html; charset=utf-8";
    set beresp.http.Retry-After = "60";
    
    synthetic({{"<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Temporarily Unavailable</title>
    <style>
        body {{
            font-family: -apple-system, BlinkMacSystemFont, sans-serif;
            display: flex; justify-content: center; align-items: center;
            min-height: 100vh; margin: 0;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
        }}
        .container {{
            text-align: center; padding: 3rem; background: white;
            border-radius: 16px; box-shadow: 0 25px 50px rgba(0,0,0,0.25);
            max-width: 500px; margin: 1rem;
        }}
        h1 {{ color: #1a1a2e; }} p {{ color: #666; }}
    </style>
</head>
<body>
    <div class="container">
        <h1>We'll be right back</h1>
        <p>We're performing some maintenance. Please try again shortly.</p>
    </div>
</body>
</html>"}});
    
    return (deliver);
}}
'''


def generate_cache_compose(varnish_size: str = "256M") -> str:
    """Generate cache docker-compose.yml"""
    return f'''networks:
  cache:
    name: cache
    driver: bridge
  web:
    external: true

services:
  redis:
    image: redis:alpine
    container_name: redis
    restart: always
    command: ["redis-server", "--appendonly", "yes"]
    networks:
      - cache
    volumes:
      - ./redis_data:/data
    labels:
      - "traefik.enable=false"

  varnish:
    image: varnish:7.6-alpine
    container_name: varnish
    restart: always
    ports:
      - "127.0.0.1:6081:80"
    volumes:
      - ./varnish/default.vcl:/etc/varnish/default.vcl:ro
    environment:
      - VARNISH_SIZE={varnish_size}
    command: >
      varnishd 
      -F 
      -f /etc/varnish/default.vcl 
      -a :80 
      -s malloc,{varnish_size}
      -p default_ttl=300
      -p default_grace=86400
      -p default_keep=604800
    networks:
      - cache
      - web
    labels:
      - "traefik.enable=false"
    healthcheck:
      test: ["CMD", "varnishd", "-V"]
      interval: 30s
      timeout: 10s
      retries: 3
'''


def generate_traefik_router(sites: List[Dict]) -> str:
    """Generate Traefik router configuration"""
    routers = []
    
    for site in sites:
        hostname = site['hostname']
        router_name = hostname.replace('.', '-').replace('_', '-')
        
        # Build host rule
        hosts = [f"Host(`{hostname}`)"]
        if not hostname.startswith('www.'):
            hosts.append(f"Host(`www.{hostname}`)")
        
        rule = ' || '.join(hosts)
        
        routers.append(f'''    {router_name}-varnish:
      rule: "{rule}"
      entryPoints:
        - websecure
      service: varnish-cache
      tls:
        certResolver: le
      middlewares:
        - wordpress-security@file
        - security-headers@file
      priority: 100''')
    
    routers_yaml = '\n\n'.join(routers)
    
    return f'''# =============================================================================
# VARNISH CACHE SERVICE AND ROUTERS
# =============================================================================
# Generated by varnish-setup on {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}
#
# Architecture: Internet → Traefik (SSL) → Varnish (Cache) → WordPress
# =============================================================================

http:
  services:
    varnish-cache:
      loadBalancer:
        servers:
          - url: "http://varnish:80"
        passHostHeader: true

  routers:
{routers_yaml}
'''


# =============================================================================
# MAIN SETUP CLASS
# =============================================================================
class VarnishSetup:
    def __init__(self, services_dir: str, dry_run: bool = False, interactive: bool = True):
        self.services_dir = Path(services_dir)
        self.dry_run = dry_run
        self.interactive = interactive
        self.sites = []
        
        # Paths
        self.cache_dir = self.services_dir / "cache"
        self.traefik_dir = self.services_dir / "traefik"
        self.varnish_dir = self.cache_dir / "varnish"
    
    def detect_existing_config(self) -> Dict:
        """Detect existing configuration"""
        config = {
            'varnish_installed': file_exists(str(self.varnish_dir / "default.vcl")),
            'cache_compose_exists': file_exists(str(self.cache_dir / "docker-compose.yml")),
            'traefik_dynamic_dir': file_exists(str(self.traefik_dir / "dynamic")),
            'wordpress_containers': get_wordpress_containers(),
        }
        return config
    
    def select_sites(self, containers: List[Dict]) -> List[Dict]:
        """Select WordPress sites to configure"""
        sites = []
        
        print_info(f"Found {len(containers)} WordPress container(s):")
        
        for i, container in enumerate(containers, 1):
            name = container['name']
            labels = get_container_labels(name)
            hostname = extract_hostname_from_labels(labels) or f"{name}.local"
            
            print(f"    {i}. {Colors.CYAN}{name}{Colors.END} → {hostname}")
            
            if self.interactive:
                if confirm(f"Include {name} in Varnish caching?", default=True):
                    custom_host = prompt(f"Hostname for {name}", default=hostname)
                    sites.append({
                        'container_name': name,
                        'backend_name': name,
                        'hostname': custom_host
                    })
            else:
                sites.append({
                    'container_name': name,
                    'backend_name': name,
                    'hostname': hostname
                })
        
        return sites
    
    def run(self):
        """Run the setup process"""
        print_header("VARNISH CACHE SETUP")
        
        if self.dry_run:
            print_warning("DRY RUN MODE - No changes will be made")
        
        print(f"  {Colors.BOLD}Configuration:{Colors.END}")
        print(f"    • Services directory: {Colors.CYAN}{self.services_dir}{Colors.END}")
        print(f"    • Interactive mode:   {Colors.CYAN}{self.interactive}{Colors.END}")
        
        total_steps = 6
        
        # ====================================================================
        # Step 1: Check Prerequisites
        # ====================================================================
        print_step(1, total_steps, "Checking prerequisites...")
        
        if not docker_available():
            print_error("Docker is not available. Please ensure Docker is installed and running.")
            return False
        print_success("Docker is available")
        
        # Check existing config
        config = self.detect_existing_config()
        
        if config['varnish_installed']:
            print_warning("Varnish configuration already exists")
            if self.interactive and not confirm("Overwrite existing configuration?", default=False):
                print_info("Setup cancelled by user")
                return False
        
        # ====================================================================
        # Step 2: Select Sites
        # ====================================================================
        print_step(2, total_steps, "Detecting WordPress containers...")
        
        containers = config['wordpress_containers']
        
        if not containers:
            print_warning("No WordPress containers found (looking for containers named wp_*)")
            if self.interactive:
                manual_name = prompt("Enter container name manually (or leave empty to skip)")
                if manual_name:
                    manual_host = prompt("Enter hostname", default=f"{manual_name}.example.com")
                    self.sites = [{
                        'container_name': manual_name,
                        'backend_name': manual_name,
                        'hostname': manual_host
                    }]
            
            if not self.sites:
                print_error("No sites configured. Setup cannot continue.")
                return False
        else:
            self.sites = self.select_sites(containers)
        
        if not self.sites:
            print_error("No sites selected for Varnish caching")
            return False
        
        print_success(f"Selected {len(self.sites)} site(s) for caching")
        
        # ====================================================================
        # Step 3: Generate Configuration
        # ====================================================================
        print_step(3, total_steps, "Generating configuration files...")
        
        # Generate VCL
        vcl_content = generate_vcl_config(self.sites)
        vcl_path = str(self.varnish_dir / "default.vcl")
        
        if file_exists(vcl_path):
            backup_file(vcl_path, self.dry_run)
        
        write_file(vcl_path, vcl_content, self.dry_run)
        
        # Generate cache docker-compose
        varnish_size = "256M"
        if self.interactive:
            varnish_size = prompt("Varnish cache size", default="256M")
        
        compose_content = generate_cache_compose(varnish_size)
        compose_path = str(self.cache_dir / "docker-compose.yml")
        
        if file_exists(compose_path):
            backup_file(compose_path, self.dry_run)
        
        write_file(compose_path, compose_content, self.dry_run)
        
        # Generate Traefik router
        router_content = generate_traefik_router(self.sites)
        router_path = str(self.traefik_dir / "dynamic" / "varnish-cache.yml")
        
        ensure_dir(str(self.traefik_dir / "dynamic"))
        write_file(router_path, router_content, self.dry_run)
        
        # ====================================================================
        # Step 4: Start Varnish
        # ====================================================================
        print_step(4, total_steps, "Starting Varnish service...")
        
        if self.dry_run:
            print_info("Would run: docker compose up -d varnish")
        else:
            code, stdout, stderr = run_command(
                f"cd {self.cache_dir} && docker compose up -d varnish",
                timeout=60
            )
            
            if code == 0:
                print_success("Varnish container started")
            else:
                print_error(f"Failed to start Varnish: {stderr}")
                return False
        
        # ====================================================================
        # Step 5: Verify Backend Health
        # ====================================================================
        print_step(5, total_steps, "Verifying backend health...")
        
        if self.dry_run:
            print_info("Would check: docker exec varnish varnishadm backend.list")
        else:
            import time
            print_info("Waiting for health probes...")
            time.sleep(20)
            
            code, stdout, _ = run_command("docker exec varnish varnishadm backend.list")
            
            if code == 0:
                print_info("Backend status:")
                for line in stdout.split('\n'):
                    if 'boot.' in line:
                        print(f"    {line}")
            else:
                print_warning("Could not check backend health")
        
        # ====================================================================
        # Step 6: Reload Traefik
        # ====================================================================
        print_step(6, total_steps, "Reloading Traefik...")
        
        if self.dry_run:
            print_info("Would reload Traefik to pick up new router config")
        else:
            # Check if Traefik has file.watch enabled
            code, stdout, _ = run_command(
                "docker inspect traefik --format '{{range .Config.Cmd}}{{println .}}{{end}}' | grep -i 'file.watch=true'"
            )
            
            if code == 0:
                print_success("Traefik has file watch enabled - config will auto-reload")
            else:
                print_warning("Traefik may need manual restart to pick up changes")
                if self.interactive and confirm("Restart Traefik now?", default=True):
                    code, _, stderr = run_command(
                        f"cd {self.traefik_dir} && docker compose up -d --force-recreate traefik",
                        timeout=60
                    )
                    if code == 0:
                        print_success("Traefik restarted")
                    else:
                        print_error(f"Failed to restart Traefik: {stderr}")
        
        # ====================================================================
        # Summary
        # ====================================================================
        print_header("SETUP COMPLETE")
        
        print(f"  {Colors.GREEN}✓ Varnish is now configured for:{Colors.END}")
        for site in self.sites:
            print(f"    • {Colors.CYAN}{site['hostname']}{Colors.END} → {site['container_name']}")
        
        print(f"\n  {Colors.BOLD}Next steps:{Colors.END}")
        print(f"    1. Test the site: curl -sI https://{self.sites[0]['hostname']} | grep x-cache")
        print(f"    2. Run stale-if-error test: python3 /var/opt/scripts/test_stale_if_error.py")
        
        print(f"\n  {Colors.BOLD}Files created:{Colors.END}")
        print(f"    • {vcl_path}")
        print(f"    • {compose_path}")
        print(f"    • {router_path}")
        
        return True


# =============================================================================
# MAIN
# =============================================================================
def main():
    parser = argparse.ArgumentParser(
        description='Interactive Varnish Cache setup for Traefik + WordPress',
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    
    parser.add_argument(
        '--services-dir',
        default='/var/opt/services',
        help='Path to services directory (default: /var/opt/services)'
    )
    
    parser.add_argument(
        '--non-interactive',
        action='store_true',
        help='Run without prompts'
    )
    
    parser.add_argument(
        '--dry-run',
        action='store_true',
        help='Show what would be done without making changes'
    )
    
    args = parser.parse_args()
    
    setup = VarnishSetup(
        services_dir=args.services_dir,
        dry_run=args.dry_run,
        interactive=not args.non_interactive
    )
    
    try:
        success = setup.run()
        sys.exit(0 if success else 1)
    except KeyboardInterrupt:
        print(f"\n{Colors.YELLOW}Setup cancelled by user{Colors.END}")
        sys.exit(1)
    except Exception as e:
        print(f"\n{Colors.RED}Error: {e}{Colors.END}")
        sys.exit(1)


if __name__ == '__main__':
    main()
