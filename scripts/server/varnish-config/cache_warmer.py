#!/usr/bin/env python3
"""
Varnish Cache Warmer
====================
Crawls a WordPress sitemap and warms the Varnish cache by requesting all URLs.

This ensures that when WordPress goes down, more pages are available from cache.

Features:
- Parses sitemap.xml and sitemap index files
- Follows nested sitemaps (posts, pages, categories, etc.)
- Configurable concurrency for faster warming
- Progress display with statistics
- Can run as a one-shot or scheduled via cron

Usage:
    python3 cache_warmer.py [options] <site_url>

Examples:
    python3 cache_warmer.py https://example.com
    python3 cache_warmer.py --concurrency 5 --timeout 30 https://example.com
    python3 cache_warmer.py --sitemap /custom-sitemap.xml https://example.com
"""

import argparse
import sys
import time
import re
import xml.etree.ElementTree as ET
from typing import List, Set, Dict, Optional, Tuple
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor, as_completed
from urllib.parse import urljoin, urlparse
import subprocess


# =============================================================================
# ANSI COLORS
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


def print_header(text: str):
    width = 70
    print(f"\n{Colors.CYAN}{'═' * width}{Colors.END}")
    print(f"{Colors.BOLD}{Colors.CYAN}{text.center(width)}{Colors.END}")
    print(f"{Colors.CYAN}{'═' * width}{Colors.END}\n")


def print_success(text: str):
    print(f"  {Colors.GREEN}✓{Colors.END} {text}")


def print_warning(text: str):
    print(f"  {Colors.YELLOW}⚠{Colors.END} {text}")


def print_error(text: str):
    print(f"  {Colors.RED}✗{Colors.END} {text}")


def print_info(text: str):
    print(f"  {Colors.CYAN}ℹ{Colors.END} {text}")


# =============================================================================
# HTTP UTILITIES
# =============================================================================
def fetch_url(url: str, timeout: int = 30) -> Tuple[bool, int, str, float]:
    """
    Fetch a URL using curl and return (success, status_code, cache_status, time_taken)
    """
    start_time = time.time()
    
    cmd = f'curl -sI --max-time {timeout} -H "Accept-Encoding: gzip" "{url}" 2>&1'
    
    try:
        result = subprocess.run(
            cmd,
            shell=True,
            capture_output=True,
            text=True,
            timeout=timeout + 5
        )
        elapsed = time.time() - start_time
        
        if result.returncode != 0:
            return False, 0, "ERROR", elapsed
        
        output = result.stdout
        
        # Parse status code
        status_code = 0
        for line in output.split('\n'):
            if line.startswith('HTTP/'):
                match = re.search(r'(\d{3})', line)
                if match:
                    status_code = int(match.group(1))
                    break
        
        # Parse cache status
        cache_status = "UNKNOWN"
        for line in output.split('\n'):
            if line.lower().startswith('x-cache:'):
                cache_status = line.split(':', 1)[1].strip()
                break
        
        success = 200 <= status_code < 400
        return success, status_code, cache_status, elapsed
        
    except subprocess.TimeoutExpired:
        return False, 0, "TIMEOUT", timeout
    except Exception as e:
        return False, 0, str(e), time.time() - start_time


def fetch_content(url: str, timeout: int = 30) -> Optional[str]:
    """Fetch URL content (for sitemaps)"""
    cmd = f'curl -sL --max-time {timeout} "{url}" 2>&1'
    
    try:
        result = subprocess.run(
            cmd,
            shell=True,
            capture_output=True,
            text=True,
            timeout=timeout + 5
        )
        
        if result.returncode == 0:
            return result.stdout
        return None
        
    except:
        return None


# =============================================================================
# SITEMAP PARSING
# =============================================================================
def parse_sitemap(content: str, base_url: str) -> Tuple[List[str], List[str]]:
    """
    Parse a sitemap and return (urls, nested_sitemaps)
    
    Handles both regular sitemaps and sitemap index files.
    """
    urls = []
    nested_sitemaps = []
    
    if not content:
        return urls, nested_sitemaps
    
    try:
        # Remove XML namespaces for easier parsing
        content = re.sub(r'\sxmlns[^"]*"[^"]*"', '', content)
        root = ET.fromstring(content)
        
        # Check if this is a sitemap index
        if root.tag == 'sitemapindex' or 'sitemapindex' in root.tag:
            # This is a sitemap index - extract nested sitemap URLs
            for sitemap in root.findall('.//sitemap'):
                loc = sitemap.find('loc')
                if loc is not None and loc.text:
                    nested_sitemaps.append(loc.text.strip())
        else:
            # This is a regular sitemap - extract URLs
            for url_elem in root.findall('.//url'):
                loc = url_elem.find('loc')
                if loc is not None and loc.text:
                    urls.append(loc.text.strip())
        
    except ET.ParseError as e:
        # Try regex fallback for malformed XML
        loc_pattern = r'<loc>([^<]+)</loc>'
        matches = re.findall(loc_pattern, content)
        
        for match in matches:
            url = match.strip()
            if 'sitemap' in url.lower() and url.endswith('.xml'):
                nested_sitemaps.append(url)
            else:
                urls.append(url)
    
    return urls, nested_sitemaps


def discover_urls(base_url: str, sitemap_path: str = "/sitemap.xml", timeout: int = 30) -> Set[str]:
    """
    Discover all URLs from a site's sitemap(s)
    """
    discovered_urls = set()
    processed_sitemaps = set()
    sitemaps_to_process = []
    
    # Normalize base URL
    if not base_url.endswith('/'):
        base_url = base_url + '/'
    
    # Start with the main sitemap
    main_sitemap = urljoin(base_url, sitemap_path.lstrip('/'))
    sitemaps_to_process.append(main_sitemap)
    
    while sitemaps_to_process:
        sitemap_url = sitemaps_to_process.pop(0)
        
        if sitemap_url in processed_sitemaps:
            continue
        
        processed_sitemaps.add(sitemap_url)
        print_info(f"Processing sitemap: {sitemap_url}")
        
        content = fetch_content(sitemap_url, timeout)
        if not content:
            print_warning(f"Could not fetch: {sitemap_url}")
            continue
        
        urls, nested = parse_sitemap(content, base_url)
        
        discovered_urls.update(urls)
        
        for nested_sitemap in nested:
            if nested_sitemap not in processed_sitemaps:
                sitemaps_to_process.append(nested_sitemap)
        
        print_info(f"  Found {len(urls)} URLs, {len(nested)} nested sitemaps")
    
    return discovered_urls


# =============================================================================
# CACHE WARMER
# =============================================================================
class CacheWarmer:
    def __init__(
        self,
        site_url: str,
        sitemap_path: str = "/sitemap.xml",
        concurrency: int = 3,
        timeout: int = 30,
        delay: float = 0.1,
        verbose: bool = False
    ):
        self.site_url = site_url
        self.sitemap_path = sitemap_path
        self.concurrency = concurrency
        self.timeout = timeout
        self.delay = delay
        self.verbose = verbose
        
        # Statistics
        self.stats = {
            'total': 0,
            'success': 0,
            'failed': 0,
            'cache_hit': 0,
            'cache_miss': 0,
            'total_time': 0.0
        }
    
    def warm_url(self, url: str) -> Dict:
        """Warm a single URL and return result"""
        success, status_code, cache_status, elapsed = fetch_url(url, self.timeout)
        
        result = {
            'url': url,
            'success': success,
            'status_code': status_code,
            'cache_status': cache_status,
            'time': elapsed
        }
        
        return result
    
    def run(self) -> Dict:
        """Run the cache warmer"""
        print_header("VARNISH CACHE WARMER")
        
        print(f"  {Colors.BOLD}Configuration:{Colors.END}")
        print(f"    • Site:        {Colors.CYAN}{self.site_url}{Colors.END}")
        print(f"    • Sitemap:     {Colors.CYAN}{self.sitemap_path}{Colors.END}")
        print(f"    • Concurrency: {Colors.CYAN}{self.concurrency}{Colors.END}")
        print(f"    • Timeout:     {Colors.CYAN}{self.timeout}s{Colors.END}")
        print()
        
        # Discover URLs
        print(f"{Colors.BLUE}[Step 1]{Colors.END} {Colors.BOLD}Discovering URLs from sitemap...{Colors.END}")
        
        urls = discover_urls(self.site_url, self.sitemap_path, self.timeout)
        
        if not urls:
            print_error("No URLs found in sitemap!")
            print_info(f"Make sure {self.site_url}{self.sitemap_path} exists and is accessible")
            return self.stats
        
        self.stats['total'] = len(urls)
        print_success(f"Found {len(urls)} URLs to warm")
        print()
        
        # Warm the cache
        print(f"{Colors.BLUE}[Step 2]{Colors.END} {Colors.BOLD}Warming cache...{Colors.END}")
        
        start_time = time.time()
        completed = 0
        
        with ThreadPoolExecutor(max_workers=self.concurrency) as executor:
            # Submit all tasks
            future_to_url = {
                executor.submit(self.warm_url, url): url 
                for url in urls
            }
            
            # Process results as they complete
            for future in as_completed(future_to_url):
                result = future.result()
                completed += 1
                
                # Update stats
                if result['success']:
                    self.stats['success'] += 1
                else:
                    self.stats['failed'] += 1
                
                cache_status = result['cache_status'].upper()
                if 'HIT' in cache_status:
                    self.stats['cache_hit'] += 1
                elif 'MISS' in cache_status:
                    self.stats['cache_miss'] += 1
                
                self.stats['total_time'] += result['time']
                
                # Progress display
                pct = (completed / len(urls)) * 100
                bar_width = 30
                filled = int(bar_width * completed / len(urls))
                bar = '█' * filled + '░' * (bar_width - filled)
                
                status_icon = Colors.GREEN + '✓' if result['success'] else Colors.RED + '✗'
                status_icon += Colors.END
                
                if self.verbose:
                    print(f"\r  [{bar}] {pct:5.1f}% ({completed}/{len(urls)}) "
                          f"{status_icon} {result['cache_status']:10} {result['url'][:50]}...")
                else:
                    print(f"\r  [{bar}] {pct:5.1f}% ({completed}/{len(urls)}) "
                          f"Hits: {self.stats['cache_hit']} | Misses: {self.stats['cache_miss']} | "
                          f"Failed: {self.stats['failed']}     ", end='', flush=True)
                
                # Small delay to be nice to the server
                if self.delay > 0:
                    time.sleep(self.delay)
        
        print()  # New line after progress bar
        
        total_elapsed = time.time() - start_time
        
        # Print summary
        print_header("CACHE WARMING COMPLETE")
        
        print(f"  {Colors.BOLD}Results:{Colors.END}")
        print(f"    • Total URLs:    {Colors.CYAN}{self.stats['total']}{Colors.END}")
        print(f"    • Successful:    {Colors.GREEN}{self.stats['success']}{Colors.END}")
        print(f"    • Failed:        {Colors.RED}{self.stats['failed']}{Colors.END}")
        print()
        print(f"  {Colors.BOLD}Cache Status:{Colors.END}")
        print(f"    • Cache Hits:    {Colors.GREEN}{self.stats['cache_hit']}{Colors.END} (already cached)")
        print(f"    • Cache Misses:  {Colors.YELLOW}{self.stats['cache_miss']}{Colors.END} (now cached)")
        print()
        print(f"  {Colors.BOLD}Performance:{Colors.END}")
        print(f"    • Total time:    {Colors.CYAN}{total_elapsed:.1f}s{Colors.END}")
        print(f"    • Avg per URL:   {Colors.CYAN}{self.stats['total_time']/max(1, self.stats['total']):.2f}s{Colors.END}")
        print(f"    • URLs/second:   {Colors.CYAN}{self.stats['total']/max(0.1, total_elapsed):.1f}{Colors.END}")
        print()
        
        if self.stats['failed'] == 0:
            print(f"  {Colors.GREEN}{Colors.BOLD}★ All URLs successfully warmed! ★{Colors.END}")
        else:
            print(f"  {Colors.YELLOW}Some URLs failed - check site accessibility{Colors.END}")
        
        print()
        
        return self.stats


# =============================================================================
# MAIN
# =============================================================================
def main():
    parser = argparse.ArgumentParser(
        description='Warm Varnish cache by crawling sitemap',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s https://example.com
  %(prog)s --concurrency 5 https://example.com
  %(prog)s --sitemap /sitemap_index.xml https://example.com
  %(prog)s --verbose https://example.com

Scheduling with cron:
  # Warm cache every hour
  0 * * * * /usr/bin/python3 /path/to/cache_warmer.py https://example.com >> /var/log/cache_warmer.log 2>&1
        """
    )
    
    parser.add_argument(
        'site_url',
        help='The site URL to warm (e.g., https://example.com)'
    )
    
    parser.add_argument(
        '--sitemap', '-m',
        default='/sitemap.xml',
        help='Path to sitemap (default: /sitemap.xml)'
    )
    
    parser.add_argument(
        '--concurrency', '-c',
        type=int,
        default=3,
        help='Number of concurrent requests (default: 3)'
    )
    
    parser.add_argument(
        '--timeout', '-t',
        type=int,
        default=30,
        help='Request timeout in seconds (default: 30)'
    )
    
    parser.add_argument(
        '--delay', '-d',
        type=float,
        default=0.1,
        help='Delay between requests in seconds (default: 0.1)'
    )
    
    parser.add_argument(
        '--verbose', '-v',
        action='store_true',
        help='Show detailed output for each URL'
    )
    
    args = parser.parse_args()
    
    # Normalize URL
    site_url = args.site_url
    if not site_url.startswith('http'):
        site_url = 'https://' + site_url
    
    warmer = CacheWarmer(
        site_url=site_url,
        sitemap_path=args.sitemap,
        concurrency=args.concurrency,
        timeout=args.timeout,
        delay=args.delay,
        verbose=args.verbose
    )
    
    try:
        stats = warmer.run()
        sys.exit(0 if stats['failed'] == 0 else 1)
    except KeyboardInterrupt:
        print(f"\n{Colors.YELLOW}Cache warming interrupted{Colors.END}")
        sys.exit(1)
    except Exception as e:
        print(f"\n{Colors.RED}Error: {e}{Colors.END}")
        sys.exit(1)


if __name__ == '__main__':
    main()
