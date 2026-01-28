#!/usr/bin/env python3

import subprocess
import json
import sys
import os
import argparse
import re
import csv
from datetime import datetime, timedelta
from typing import List, Dict, Optional, Tuple
import logging
import urllib.request
import urllib.error

# Python whois library
try:
    import whois
    WHOIS_AVAILABLE = True
except ImportError:
    WHOIS_AVAILABLE = False
    logging.warning("python-whois library not available, will fall back to system whois command")

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[logging.StreamHandler()]
)


class DomainExpiryChecker:
    DEFAULT_WHOIS_TIMEOUT = 30
    DEFAULT_WHOIS_RETRIES = 2
    DEFAULT_RDAP_TIMEOUT = 15

    WHOIS_SERVERS_BY_TLD = {
        'com': ['whois.verisign-grs.com', 'whois.crsnic.net'],
        'net': ['whois.verisign-grs.com', 'whois.crsnic.net'],
        'org': ['whois.pir.org'],
        'io': ['whois.nic.io'],
        'co': ['whois.nic.co'],
        'us': ['whois.nic.us'],
        'info': ['whois.afilias.net'],
    }

    RDAP_ENDPOINTS_BY_TLD = {
        'com': ['https://rdap.verisign.com/com/v1/domain/'],
        'net': ['https://rdap.verisign.com/net/v1/domain/'],
        'org': ['https://rdap.publicinterestregistry.org/rdap/org/domain/'],
    }

    RDAP_FALLBACK_ENDPOINTS = [
        'https://rdap.org/domain/',
    ]

    def __init__(self, days_threshold: int = 30, dry_run: bool = False, verbose: bool = False,
                 whois_timeout: int = DEFAULT_WHOIS_TIMEOUT, whois_retries: int = DEFAULT_WHOIS_RETRIES,
                 rdap_timeout: int = DEFAULT_RDAP_TIMEOUT):
        self.days_threshold = days_threshold
        self.dry_run = dry_run
        self.verbose = verbose
        self.whois_timeout = whois_timeout
        self.whois_retries = whois_retries
        self.rdap_timeout = rdap_timeout
        if self.verbose:
            logging.getLogger().setLevel(logging.DEBUG)
        
    def log(self, msg, level=logging.INFO):
        if self.verbose or level >= logging.INFO:
            logging.log(level, msg)

    def get_wp_containers(self) -> List[str]:
        """Get all Docker containers with names starting with 'wp_'"""
        self.log("Getting all Docker containers with names starting with 'wp_'", logging.DEBUG)
        try:
            result = subprocess.run(['docker', 'ps', '--format', '{{.Names}}'],
                                    capture_output=True, text=True, check=True)
            containers = [line.strip() for line in result.stdout.split('\n') if line.strip().startswith('wp_')]
            self.log(f"Found {len(containers)} WordPress containers", logging.DEBUG)
            return containers
        except subprocess.CalledProcessError as e:
            self.log(f"Error getting Docker containers: {e}", logging.ERROR)
            sys.exit(1)

    def get_site_url(self, container_name: str) -> Optional[str]:
        """Extract WP_HOME or site URL from container env."""
        try:
            cmd = ['docker', 'inspect', container_name]
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)
            inspect_data = json.loads(result.stdout)
            envs = inspect_data[0].get('Config', {}).get('Env', [])
            for env_var in envs:
                if env_var.startswith('WP_HOME='):
                    url = env_var.split('=', 1)[1]
                    # Remove protocol and trailing slashes
                    domain = url.replace('https://', '').replace('http://', '').strip('/')
                    # Remove path if present
                    domain = domain.split('/')[0]
                    return domain
        except Exception as e:
            self.log(f"Could not extract site URL from {container_name}: {e}", logging.WARNING)
        return None

    def extract_domain(self, url: str) -> str:
        """Extract base domain from URL"""
        # Remove protocol
        domain = url.replace('https://', '').replace('http://', '').strip('/')
        # Remove path
        domain = domain.split('/')[0]
        # Remove port
        domain = domain.split(':')[0]
        # Remove www. prefix for whois lookups
        if domain.startswith('www.'):
            domain = domain[4:]
        return domain

    def _get_tld(self, domain: str) -> str:
        parts = domain.lower().strip('.').split('.')
        return parts[-1] if parts else ''

    def _get_whois_servers(self, domain: str) -> List[Optional[str]]:
        tld = self._get_tld(domain)
        servers = self.WHOIS_SERVERS_BY_TLD.get(tld, [])
        return servers + [None]

    def _get_rdap_endpoints(self, domain: str) -> List[str]:
        tld = self._get_tld(domain)
        endpoints = self.RDAP_ENDPOINTS_BY_TLD.get(tld, [])
        return endpoints + self.RDAP_FALLBACK_ENDPOINTS

    def _normalize_datetime(self, dt: datetime) -> datetime:
        if dt.tzinfo is not None:
            return dt.replace(tzinfo=None)
        return dt

    def _parse_rdap_expiry(self, data: Dict) -> Optional[datetime]:
        events = data.get('events', []) if isinstance(data, dict) else []
        for event in events:
            action = (event.get('eventAction') or '').lower()
            if action in {'expiration', 'expiry', 'expires'}:
                date_str = event.get('eventDate')
                if not date_str:
                    continue
                try:
                    return datetime.fromisoformat(date_str.replace('Z', '+00:00'))
                except ValueError:
                    continue
        return None

    def check_expiry_with_python_whois(self, domain: str) -> Optional[Tuple[datetime, int]]:
        """Check domain expiry using python-whois library"""
        if not WHOIS_AVAILABLE:
            return None
        
        try:
            self.log(f"Querying WHOIS for {domain} using python-whois...", logging.DEBUG)
            w = whois.whois(domain)
            
            # Handle both single date and list of dates
            expiry_date = w.expiration_date
            if isinstance(expiry_date, list):
                expiry_date = expiry_date[0]
            
            if not expiry_date:
                self.log(f"No expiry date found for {domain}", logging.WARNING)
                return None
            
            # Ensure we have a datetime object
            if not isinstance(expiry_date, datetime):
                self.log(f"Invalid expiry date format for {domain}: {expiry_date}", logging.WARNING)
                return None
            
            expiry_date = self._normalize_datetime(expiry_date)
            days_until_expiry = (expiry_date - datetime.now()).days
            return (expiry_date, days_until_expiry)
            
        except Exception as e:
            self.log(f"Error querying WHOIS for {domain}: {e}", logging.DEBUG)
            return None

    def check_expiry_with_system_whois(self, domain: str) -> Optional[Tuple[datetime, int]]:
        """Check domain expiry using system whois command with fallbacks and retries"""
        servers = self._get_whois_servers(domain)
        expiry_patterns = [
            r'expiry date:\s*(\d{4}-\d{2}-\d{2})',
            r'expiration date:\s*(\d{4}-\d{2}-\d{2})',
            r'expire date:\s*(\d{4}-\d{2}-\d{2})',
            r'registry expiry date:\s*(\d{4}-\d{2}-\d{2})',
            r'expiration time:\s*(\d{4}-\d{2}-\d{2})',
            r'paid-till:\s*(\d{4}-\d{2}-\d{2})',
            r'expiry date:\s*(\d{4}-\d{2}-\d{2}t\d{2}:\d{2}:\d{2})',
            r'expiration date:\s*(\d{4}-\d{2}-\d{2}t\d{2}:\d{2}:\d{2})',
            r'expiration date:\s*(\d{2}/\d{2}/\d{4})',
            r'expiry date:\s*(\d{2}/\d{2}/\d{4})',
        ]

        forbidden_patterns = [
            r'access denied',
            r'query rate limit',
            r'quota exceeded',
            r'forbidden',
            r'not permitted',
        ]

        for server in servers:
            server_desc = server or 'default whois server'
            for attempt in range(1, self.whois_retries + 1):
                try:
                    self.log(
                        f"Querying WHOIS for {domain} using system whois ({server_desc}), attempt {attempt}/{self.whois_retries}...",
                        logging.DEBUG
                    )
                    cmd = ['whois', domain] if not server else ['whois', '-h', server, domain]
                    result = subprocess.run(cmd, capture_output=True, text=True, timeout=self.whois_timeout)

                    if result.returncode != 0:
                        self.log(f"WHOIS command failed for {domain} via {server_desc}", logging.WARNING)
                        continue

                    output = result.stdout.lower()

                    if any(re.search(pat, output) for pat in forbidden_patterns):
                        self.log(f"WHOIS access/rate-limit issue for {domain} via {server_desc}", logging.WARNING)
                        continue

                    for pattern in expiry_patterns:
                        match = re.search(pattern, output)
                        if match:
                            date_str = match.group(1)
                            try:
                                if 't' in date_str:
                                    expiry_date = datetime.fromisoformat(date_str.replace('z', '+00:00'))
                                elif '/' in date_str:
                                    expiry_date = datetime.strptime(date_str, '%m/%d/%Y')
                                else:
                                    expiry_date = datetime.strptime(date_str, '%Y-%m-%d')

                                expiry_date = self._normalize_datetime(expiry_date)
                                days_until_expiry = (expiry_date - datetime.now()).days
                                return (expiry_date, days_until_expiry)
                            except ValueError as e:
                                self.log(f"Could not parse date '{date_str}' for {domain}: {e}", logging.DEBUG)
                                continue

                    self.log(f"Could not find expiry date in WHOIS output for {domain} via {server_desc}", logging.WARNING)
                except subprocess.TimeoutExpired:
                    self.log(f"WHOIS query timed out for {domain} via {server_desc} (attempt {attempt})", logging.WARNING)
                except Exception as e:
                    self.log(f"Error running system whois for {domain} via {server_desc}: {e}", logging.WARNING)

        return None

    def check_expiry_with_rdap(self, domain: str) -> Optional[Tuple[datetime, int]]:
        """Check domain expiry using RDAP HTTP endpoints"""
        for endpoint in self._get_rdap_endpoints(domain):
            url = f"{endpoint}{domain}"
            try:
                self.log(f"Querying RDAP for {domain}: {url}", logging.DEBUG)
                with urllib.request.urlopen(url, timeout=self.rdap_timeout) as resp:
                    if resp.status != 200:
                        self.log(f"RDAP request failed for {domain} with status {resp.status}", logging.WARNING)
                        continue
                    data = json.loads(resp.read().decode('utf-8'))
                    expiry_date = self._parse_rdap_expiry(data)
                    if not expiry_date:
                        self.log(f"No RDAP expiry date found for {domain} from {url}", logging.DEBUG)
                        continue
                    expiry_date = self._normalize_datetime(expiry_date)
                    days_until_expiry = (expiry_date - datetime.now()).days
                    return (expiry_date, days_until_expiry)
            except urllib.error.HTTPError as e:
                self.log(f"RDAP HTTP error for {domain} via {url}: {e}", logging.WARNING)
            except urllib.error.URLError as e:
                self.log(f"RDAP URL error for {domain} via {url}: {e}", logging.WARNING)
            except Exception as e:
                self.log(f"RDAP error for {domain} via {url}: {e}", logging.WARNING)
        return None

    def check_domain_expiry(self, domain: str) -> Optional[Tuple[datetime, int]]:
        """Check domain expiry using available methods"""
        # Try python-whois first if available
        if WHOIS_AVAILABLE:
            result = self.check_expiry_with_python_whois(domain)
            if result:
                return result
        
        # Fallback to system whois
        result = self.check_expiry_with_system_whois(domain)
        if result:
            return result

        # Final fallback to RDAP
        return self.check_expiry_with_rdap(domain)

    def format_expiry_status(self, domain: str, expiry_date: datetime, days_until_expiry: int) -> str:
        """Format expiry status message"""
        if days_until_expiry < 0:
            return f"🔴 EXPIRED: {domain} expired {abs(days_until_expiry)} days ago (on {expiry_date.strftime('%Y-%m-%d')})"
        elif days_until_expiry <= 7:
            return f"🔴 CRITICAL: {domain} expires in {days_until_expiry} days (on {expiry_date.strftime('%Y-%m-%d')})"
        elif days_until_expiry <= self.days_threshold:
            return f"🟡 WARNING: {domain} expires in {days_until_expiry} days (on {expiry_date.strftime('%Y-%m-%d')})"
        else:
            return f"✅ OK: {domain} expires in {days_until_expiry} days (on {expiry_date.strftime('%Y-%m-%d')})"

    def check_all_domains(self, specific_container: Optional[str] = None) -> Dict[str, Dict]:
        """Check expiry dates for all WordPress containers or a specific one"""
        containers = [specific_container] if specific_container else self.get_wp_containers()
        
        results = {
            'checked': [],
            'expiring_soon': [],
            'expired': [],
            'errors': []
        }
        
        for container in containers:
            if not container:
                continue
                
            domain = self.get_site_url(container)
            if not domain:
                self.log(f"⚠️  Could not determine domain for container {container}", logging.WARNING)
                results['errors'].append({
                    'container': container,
                    'error': 'Could not determine domain'
                })
                continue
            
            # Extract base domain for whois lookup
            base_domain = self.extract_domain(domain)
            
            self.log(f"Checking expiry for {domain} (container: {container})", logging.INFO)
            
            if self.dry_run:
                self.log(f"  🔍 DRY RUN: Would check WHOIS for {base_domain}", logging.INFO)
                # Simulate some results for testing
                fake_expiry = datetime.now() + timedelta(days=45)
                fake_days = 45
                status_msg = self.format_expiry_status(base_domain, fake_expiry, fake_days)
                self.log(f"  {status_msg}", logging.INFO)
                results['checked'].append({
                    'container': container,
                    'domain': domain,
                    'base_domain': base_domain,
                    'expiry_date': fake_expiry.strftime('%Y-%m-%d'),
                    'days_until_expiry': fake_days,
                    'status': 'ok'
                })
                continue
            
            expiry_info = self.check_domain_expiry(base_domain)
            
            if not expiry_info:
                self.log(f"  ❌ Could not retrieve expiry information for {base_domain}", logging.WARNING)
                results['errors'].append({
                    'container': container,
                    'domain': domain,
                    'base_domain': base_domain,
                    'error': 'Could not retrieve WHOIS information'
                })
                continue
            
            expiry_date, days_until_expiry = expiry_info
            status_msg = self.format_expiry_status(base_domain, expiry_date, days_until_expiry)
            self.log(f"  {status_msg}", logging.INFO)
            
            result_item = {
                'container': container,
                'domain': domain,
                'base_domain': base_domain,
                'expiry_date': expiry_date.strftime('%Y-%m-%d'),
                'days_until_expiry': days_until_expiry
            }
            
            results['checked'].append(result_item)
            
            if days_until_expiry < 0:
                result_item['status'] = 'expired'
                results['expired'].append(result_item)
            elif days_until_expiry <= self.days_threshold:
                result_item['status'] = 'expiring_soon'
                results['expiring_soon'].append(result_item)
            else:
                result_item['status'] = 'ok'
        
        return results

    def print_summary(self, results: Dict):
        """Print summary of domain expiry check results"""
        print("\n" + "="*80)
        print("DOMAIN EXPIRY CHECK SUMMARY")
        print("="*80)
        
        print(f"\n📊 Total domains checked: {len(results['checked'])}")
        print(f"🟡 Expiring within {self.days_threshold} days: {len(results['expiring_soon'])}")
        print(f"🔴 Expired: {len(results['expired'])}")
        print(f"❌ Errors: {len(results['errors'])}")
        
        if results['expired']:
            print("\n" + "="*80)
            print("🔴 EXPIRED DOMAINS:")
            print("="*80)
            for item in results['expired']:
                print(f"  {item['base_domain']} (container: {item['container']})")
                print(f"    Expired: {abs(item['days_until_expiry'])} days ago")
                print(f"    Expiry date: {item['expiry_date']}")
        
        if results['expiring_soon']:
            print("\n" + "="*80)
            print(f"🟡 DOMAINS EXPIRING WITHIN {self.days_threshold} DAYS:")
            print("="*80)
            for item in results['expiring_soon']:
                print(f"  {item['base_domain']} (container: {item['container']})")
                print(f"    Days remaining: {item['days_until_expiry']}")
                print(f"    Expiry date: {item['expiry_date']}")
        
        if results['errors']:
            print("\n" + "="*80)
            print("❌ ERRORS:")
            print("="*80)
            for item in results['errors']:
                print(f"  {item.get('domain', item['container'])}: {item['error']}")
        
        print("\n" + "="*80 + "\n")

    def output_as_csv(self, results: Dict, filepath: str):
        """Output results as CSV file"""
        rows = []
        
        for item in results['checked']:
            rows.append({
                'Container': item['container'],
                'Domain': item['domain'],
                'Base Domain': item['base_domain'],
                'Expiry Date': item['expiry_date'],
                'Days Until Expiry': item['days_until_expiry'],
                'Status': item.get('status', 'unknown')
            })
        
        # Add errors
        for item in results['errors']:
            rows.append({
                'Container': item['container'],
                'Domain': item.get('domain', ''),
                'Base Domain': item.get('base_domain', ''),
                'Expiry Date': 'ERROR',
                'Days Until Expiry': '',
                'Status': 'error',
                'Error': item['error']
            })
        
        if not rows:
            self.log("No data to write to CSV", logging.WARNING)
            return
        
        # Get all unique keys
        fieldnames = ['Container', 'Domain', 'Base Domain', 'Expiry Date', 'Days Until Expiry', 'Status']
        if any('Error' in row for row in rows):
            fieldnames.append('Error')
        
        try:
            with open(filepath, 'w', newline='', encoding='utf-8') as csvfile:
                writer = csv.DictWriter(csvfile, fieldnames=fieldnames, extrasaction='ignore')
                writer.writeheader()
                for row in rows:
                    writer.writerow(row)
            
            self.log(f"CSV output written to {filepath}", logging.INFO)
            print(f"✅ Results saved to {filepath}")
        except Exception as e:
            self.log(f"Error writing CSV file: {e}", logging.ERROR)
            sys.exit(1)

    def output_as_text_table(self, results: Dict, filepath: str):
        """Output results as formatted text table file"""
        lines = []
        
        # Header
        lines.append("="*100)
        lines.append("DOMAIN EXPIRY CHECK RESULTS")
        lines.append("="*100)
        lines.append("")
        
        # Summary
        lines.append(f"Total domains checked: {len(results['checked'])}")
        lines.append(f"Expiring within {self.days_threshold} days: {len(results['expiring_soon'])}")
        lines.append(f"Expired: {len(results['expired'])}")
        lines.append(f"Errors: {len(results['errors'])}")
        lines.append("")
        
        # All checked domains table
        if results['checked']:
            lines.append("="*100)
            lines.append("ALL DOMAINS")
            lines.append("="*100)
            lines.append(f"{'Container':<30} {'Domain':<30} {'Expiry Date':<15} {'Days':<10} {'Status':<10}")
            lines.append("-"*100)
            
            for item in results['checked']:
                status = item.get('status', 'unknown').upper()
                status_symbol = {
                    'expired': '🔴',
                    'expiring_soon': '🟡',
                    'ok': '✅',
                    'unknown': '❓'
                }.get(item.get('status', 'unknown'), '❓')
                
                lines.append(
                    f"{item['container']:<30} "
                    f"{item['base_domain']:<30} "
                    f"{item['expiry_date']:<15} "
                    f"{str(item['days_until_expiry']):<10} "
                    f"{status_symbol} {status}"
                )
            lines.append("")
        
        # Errors table
        if results['errors']:
            lines.append("="*100)
            lines.append("ERRORS")
            lines.append("="*100)
            for item in results['errors']:
                lines.append(f"Container: {item['container']}")
                if 'domain' in item:
                    lines.append(f"  Domain: {item['domain']}")
                lines.append(f"  Error: {item['error']}")
                lines.append("")
        
        lines.append("="*100)
        
        try:
            with open(filepath, 'w', encoding='utf-8') as f:
                f.write('\n'.join(lines))
            
            self.log(f"Text table output written to {filepath}", logging.INFO)
            print(f"✅ Results saved to {filepath}")
        except Exception as e:
            self.log(f"Error writing text file: {e}", logging.ERROR)
            sys.exit(1)

    def output_as_json(self, results: Dict, filepath: str):
        """Output results as JSON file"""
        try:
            with open(filepath, 'w', encoding='utf-8') as f:
                json.dump(results, f, indent=2, default=str)
            
            self.log(f"JSON output written to {filepath}", logging.INFO)
            print(f"✅ Results saved to {filepath}")
        except Exception as e:
            self.log(f"Error writing JSON file: {e}", logging.ERROR)
            sys.exit(1)


def main():
    parser = argparse.ArgumentParser(
        description='Check domain expiry dates for WordPress installations',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Check all WordPress containers
  python main.py
  
  # Check with 60-day threshold
  python main.py --days 60
  
  # Check specific container
  python main.py --container wp_example_com
  
  # Dry run mode
  python main.py --dry-run
  
  # Verbose output
  python main.py -v
  
  # Output results to file (format auto-detected from extension)
  python main.py --output results.json
  python main.py --output results.csv
  python main.py --output results.txt
  
  # Legacy: Output results as JSON to stdout
  python main.py --json > results.json
        """
    )
    
    parser.add_argument('--container', '-c', type=str,
                        help='Specific WordPress container to check')
    parser.add_argument('--days', '-d', type=int, default=30,
                        help='Number of days threshold for expiry warning (default: 30)')
    parser.add_argument('--dry-run', action='store_true',
                        help='Perform a dry run without actually querying WHOIS')
    parser.add_argument('--verbose', '-v', action='store_true',
                        help='Enable verbose logging')
    parser.add_argument('--output', '-o', type=str,
                        help='Output file path (format auto-detected: .json, .csv, or .txt)')
    parser.add_argument('--json', action='store_true',
                        help='Output results as JSON to stdout (legacy, use --output instead)')
    parser.add_argument('--whois-timeout', type=int, default=DomainExpiryChecker.DEFAULT_WHOIS_TIMEOUT,
                        help='WHOIS command timeout in seconds (default: 30)')
    parser.add_argument('--whois-retries', type=int, default=DomainExpiryChecker.DEFAULT_WHOIS_RETRIES,
                        help='WHOIS retry attempts per server (default: 2)')
    parser.add_argument('--rdap-timeout', type=int, default=DomainExpiryChecker.DEFAULT_RDAP_TIMEOUT,
                        help='RDAP HTTP timeout in seconds (default: 15)')
    
    args = parser.parse_args()
    
    checker = DomainExpiryChecker(
        days_threshold=args.days,
        dry_run=args.dry_run,
        verbose=args.verbose,
        whois_timeout=args.whois_timeout,
        whois_retries=args.whois_retries,
        rdap_timeout=args.rdap_timeout
    )
    
    results = checker.check_all_domains(specific_container=args.container)
    
    # Handle output options
    if args.output:
        # Determine format from file extension
        ext = os.path.splitext(args.output)[1].lower()
        
        if ext == '.json':
            checker.output_as_json(results, args.output)
        elif ext == '.csv':
            checker.output_as_csv(results, args.output)
        elif ext == '.txt':
            checker.output_as_text_table(results, args.output)
        else:
            print(f"❌ Unsupported file extension: {ext}")
            print("   Supported formats: .json, .csv, .txt")
            sys.exit(1)
    elif args.json:
        # Legacy JSON output to stdout
        print(json.dumps(results, indent=2, default=str))
    else:
        # Default: print summary to console
        checker.print_summary(results)
    
    # Exit with error code if there are expired domains or expiring soon
    if results['expired'] or results['expiring_soon']:
        sys.exit(1)
    else:
        sys.exit(0)


if __name__ == '__main__':
    main()
