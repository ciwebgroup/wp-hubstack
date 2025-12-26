# Varnish Cache Setup for Traefik + WordPress

A complete setup guide and installation toolkit for adding Varnish Cache with **stale-if-error** support to a Dockerized Traefik + WordPress environment.

## 🌟 Features

- **Stale-If-Error Support**: Serve cached content even when WordPress is completely down
- **24-Hour Grace Period**: Serve stale content while refreshing in background
- **7-Day Keep Period**: Serve stale content during extended outages
- **WordPress Optimized**: Smart caching rules that bypass admin, login, cart, etc.
- **Multi-Site Support**: Configure multiple WordPress backends
- **Health Monitoring**: Automatic backend health checking
- **Easy Integration**: Works with existing Traefik + Docker setup

## 📋 Prerequisites

Before you begin, ensure you have:

- [ ] Docker and Docker Compose installed
- [ ] Traefik running as a reverse proxy
- [ ] One or more WordPress containers on the `web` network
- [ ] Access to the Traefik configuration directory

## 🏗️ Architecture Overview

```
                                    ┌─────────────────┐
                                    │   WordPress 1   │
                                    └────────▲────────┘
                                             │
┌──────────┐     ┌──────────┐     ┌──────────┴──────────┐
│ Internet │────▶│ Traefik  │────▶│      Varnish        │
└──────────┘     │  (SSL)   │     │  (Cache + Stale)    │
                 └──────────┘     └──────────┬──────────┘
                                             │
                                    ┌────────▼────────┐
                                    │   WordPress 2   │
                                    └─────────────────┘
```

**Traffic Flow:**
1. Client makes HTTPS request
2. Traefik terminates SSL and applies security middlewares
3. Traefik routes to Varnish
4. Varnish checks cache → serves cached content OR fetches from WordPress
5. If WordPress is down, Varnish serves stale cached content

## 🚀 Quick Start

### Option 1: Automated Setup (Recommended)

```bash
# Run the interactive setup script
python3 setup.py

# Or run with Docker (no Python required on host)
docker compose run --rm varnish-setup
```

### Option 2: Manual Setup

Follow the [Manual Installation](#manual-installation) section below.

---

## 📦 Directory Structure

```
varnish-setup/
├── README.md                    # This file
├── setup.py                     # Interactive setup script
├── cache_warmer.py              # Sitemap-based cache warmer
├── Dockerfile                   # Docker image for setup script
├── docker-compose.yml           # Docker Compose for setup
└── templates/
    ├── varnish/
    │   └── default.vcl          # Varnish configuration template
    └── traefik/
        └── varnish-cache.yml    # Traefik router template
```

---

## 🔧 Manual Installation

### Step 1: Create the Varnish Directory

```bash
# Create directory structure in your services folder
mkdir -p /var/opt/services/cache/varnish
```

### Step 2: Copy the Varnish VCL Configuration

Copy `templates/varnish/default.vcl` to `/var/opt/services/cache/varnish/default.vcl`.

Then edit the file to add your WordPress backends:

```vcl
# Add a backend for each WordPress site
backend wp_yoursite {
    .host = "wp_yoursite";           # Container name
    .port = "80";
    .connect_timeout = 5s;
    .first_byte_timeout = 30s;
    .between_bytes_timeout = 10s;
    
    .probe = {
        .request =
            "HEAD / HTTP/1.1"
            "Host: localhost"
            "Connection: close";
        .timeout = 3s;
        .interval = 15s;
        .window = 5;
        .threshold = 3;
        .expected_response = 301;    # WordPress redirects HTTP to HTTPS
    }
}
```

Add routing in `vcl_recv`:

```vcl
sub vcl_recv {
    # Route based on hostname
    if (req.http.host ~ "yoursite") {
        set req.backend_hint = wp_yoursite;
    }
    # ... rest of configuration
}
```

### Step 3: Update the Cache docker-compose.yml

Add the Varnish service to `/var/opt/services/cache/docker-compose.yml`:

```yaml
networks:
  cache:
    name: cache
    driver: bridge
  web:
    external: true

services:
  # ... existing services (redis, etc.)
  
  varnish:
    image: varnish:7.6-alpine
    container_name: varnish
    restart: always
    ports:
      - "127.0.0.1:6081:80"
    volumes:
      - ./varnish/default.vcl:/etc/varnish/default.vcl:ro
    environment:
      - VARNISH_SIZE=256M
    command: >
      varnishd 
      -F 
      -f /etc/varnish/default.vcl 
      -a :80 
      -s malloc,256M
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
```

### Step 4: Start Varnish

```bash
cd /var/opt/services/cache
docker compose up -d varnish
```

### Step 5: Verify Varnish is Running

```bash
# Check container is running
docker ps | grep varnish

# Check backend health
docker exec varnish varnishadm backend.list
```

Expected output:
```
Backend name           Admin   Probe   Health    Last change
boot.wp_yoursite       probe   5/5     healthy   ...
```

### Step 6: Configure Traefik Dynamic Config

#### Option A: Directory-based Config (Recommended)

1. Update your Traefik docker-compose.yml to use directory-based config:

```yaml
volumes:
  - ./dynamic:/etc/traefik/dynamic:ro
  
command:
  - '--providers.file.directory=/etc/traefik/dynamic'
  - '--providers.file.watch=true'
```

2. Copy `templates/traefik/varnish-cache.yml` to `/var/opt/services/traefik/dynamic/varnish-cache.yml`

3. Edit the file to add your sites:

```yaml
http:
  services:
    varnish-cache:
      loadBalancer:
        servers:
          - url: "http://varnish:80"
        passHostHeader: true

  routers:
    yoursite-varnish:
      rule: "Host(`yoursite.com`) || Host(`www.yoursite.com`)"
      entryPoints:
        - websecure
      service: varnish-cache
      tls:
        certResolver: le
      middlewares:
        - wordpress-security@file
        - security-headers@file
      priority: 100
```

4. Restart Traefik:

```bash
cd /var/opt/services/traefik
docker compose up -d --force-recreate traefik
```

#### Option B: Single-file Config

If you prefer a single dynamic config file, add the services and routers to your existing `dynamic_conf.yml`.

### Step 7: Test the Setup

```bash
# Test with curl
curl -sI https://yoursite.com | grep -iE "x-cache|http/"

# Expected output:
# HTTP/2 200
# x-cache: HIT (or MISS on first request)
# x-cache-backend: Varnish-7.6
```

---

## 🧪 Testing Stale-If-Error

Use the provided test script to verify stale-if-error works:

```bash
# Copy the test script
cp /var/opt/scripts/test_stale_if_error.py /var/opt/scripts/

# Run the test
python3 /var/opt/scripts/test_stale_if_error.py \
    --site https://yoursite.com \
    --container wp_yoursite
```

Or manually test:

```bash
# 1. Make a request to prime cache
curl -sI https://yoursite.com

# 2. Pause the WordPress container
docker pause wp_yoursite

# 3. Wait 60 seconds for Varnish to detect sick backend

# 4. Request again - should still work!
curl -sI https://yoursite.com | grep x-cache
# Expected: x-cache: HIT

# 5. Unpause the container
docker unpause wp_yoursite
```

---

## 📖 Configuration Reference

### Varnish Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `default_ttl` | 300s | Time cached content is considered fresh |
| `default_grace` | 86400s (24h) | Grace period for stale-while-revalidate |
| `default_keep` | 604800s (7d) | Keep period for stale-if-error |
| `VARNISH_SIZE` | 256M | Cache size in memory |

### VCL Key Settings

```vcl
# In vcl_backend_response:
set beresp.grace = 24h;   # Serve stale while refreshing
set beresp.keep = 7d;     # Serve stale when backend DOWN
set beresp.ttl = 5m;      # Fresh cache duration
```

### Cache Headers

| Header | Values | Description |
|--------|--------|-------------|
| `X-Cache` | HIT, MISS, STALE-IF-ERROR, STALE-GRACE | Cache status |
| `X-Cache-Hits` | number | Hit count for this cached object |
| `X-Cache-Backend` | Varnish-7.6 | Identifies Varnish as cache layer |
| `Age` | seconds | How old the cached content is |

---

## 🔄 Adding More Sites

To add another WordPress site to Varnish caching:

### 1. Add Backend in VCL

Edit `/var/opt/services/cache/varnish/default.vcl`:

```vcl
# Add new backend
backend wp_newsite {
    .host = "wp_newsite";
    .port = "80";
    .connect_timeout = 5s;
    .first_byte_timeout = 30s;
    .between_bytes_timeout = 10s;
    
    .probe = {
        .request =
            "HEAD / HTTP/1.1"
            "Host: localhost"
            "Connection: close";
        .timeout = 3s;
        .interval = 15s;
        .window = 5;
        .threshold = 3;
        .expected_response = 301;
    }
}

# In vcl_init, add to director:
sub vcl_init {
    new wordpress = directors.round_robin();
    wordpress.add_backend(wp_yoursite);
    wordpress.add_backend(wp_newsite);    # Add this
}

# In vcl_recv, add routing:
sub vcl_recv {
    if (req.http.host ~ "newsite") {
        set req.backend_hint = wp_newsite;
    }
    # ... existing routes
}
```

### 2. Add Traefik Router

Edit `/var/opt/services/traefik/dynamic/varnish-cache.yml`:

```yaml
http:
  routers:
    # ... existing routers
    
    newsite-varnish:
      rule: "Host(`newsite.com`) || Host(`www.newsite.com`)"
      entryPoints:
        - websecure
      service: varnish-cache
      tls:
        certResolver: le
      middlewares:
        - wordpress-security@file
        - security-headers@file
      priority: 100
```

### 3. Restart Services

```bash
# Restart Varnish to load new VCL
docker compose -f /var/opt/services/cache/docker-compose.yml restart varnish

# Traefik will auto-reload if watch=true, or restart it:
# docker compose -f /var/opt/services/traefik/docker-compose.yml restart traefik
```

---

## 🛠️ Maintenance Commands

### View Cache Statistics

```bash
docker exec varnish varnishstat
```

### View Real-time Logs

```bash
docker exec varnish varnishlog
```

### Purge Specific URL

```bash
curl -X PURGE http://127.0.0.1:6081/page-to-purge -H "Host: yoursite.com"
```

### Ban Pattern (Purge Multiple)

```bash
docker exec varnish varnishadm "ban req.url ~ /wp-content/"
```

### Check Backend Health

```bash
docker exec varnish varnishadm backend.list
```

### Reload VCL Without Restart

```bash
docker exec varnish varnishadm vcl.load reload /etc/varnish/default.vcl
docker exec varnish varnishadm vcl.use reload
```

---

## ❓ Troubleshooting

### Site Returns 503 Error

1. **Check Varnish logs:**
   ```bash
   docker logs varnish
   ```

2. **Check backend health:**
   ```bash
   docker exec varnish varnishadm backend.list
   ```

3. **Verify Varnish can reach WordPress:**
   ```bash
   docker exec varnish wget -qO- --timeout=5 http://wp_yoursite/ | head
   ```

### Backend Shows "sick"

1. **Check if container is running:**
   ```bash
   docker ps | grep wp_yoursite
   ```

2. **Test probe manually:**
   ```bash
   docker exec varnish wget -qS -O /dev/null http://wp_yoursite/ 2>&1 | head
   ```
   
   If it returns 301 (redirect), ensure `.expected_response = 301;` is set in probe.

### Redirect Loop (301 → 301 → ...)

This happens when WordPress doesn't know the original request was HTTPS.

**Fix:** Ensure VCL passes `X-Forwarded-Proto`:

```vcl
sub vcl_recv {
    if (!req.http.X-Forwarded-Proto) {
        set req.http.X-Forwarded-Proto = "https";
    }
    # ...
}
```

### Cache Not Working (Always MISS)

1. **Check WordPress cookies:**
   - Logged-in users won't be cached
   - Clear browser cookies and test again

2. **Check Cache-Control headers:**
   ```bash
   curl -sI https://yoursite.com | grep -i cache-control
   ```

3. **Verify VCL is forcing TTL:**
   The VCL should override `max-age=0` for anonymous users.

---

## 🔥 Cache Warmer

The cache warmer ensures all pages are cached **before** an outage occurs. Without warming, only pages that users have visited will be in the cache.

### How It Works

1. Fetches your site's `sitemap.xml`
2. Parses all URLs (including nested sitemaps for posts, pages, etc.)
3. Requests each URL to populate the Varnish cache
4. Reports statistics on cache hits/misses

### Basic Usage

```bash
# Warm cache for a site
python3 cache_warmer.py https://example.com

# With custom sitemap path
python3 cache_warmer.py --sitemap /sitemap_index.xml https://example.com
```

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `--sitemap`, `-m` | /sitemap.xml | Path to sitemap |
| `--concurrency`, `-c` | 3 | Number of concurrent requests |
| `--timeout`, `-t` | 30 | Request timeout in seconds |
| `--delay`, `-d` | 0.1 | Delay between requests |
| `--verbose`, `-v` | false | Show details for each URL |

### Examples

```bash
# Fast warming with 5 concurrent requests
python3 cache_warmer.py -c 5 https://example.com

# Gentle warming (slower, less server load)
python3 cache_warmer.py -c 1 -d 0.5 https://example.com

# Verbose output showing each URL
python3 cache_warmer.py --verbose https://example.com
```

### Schedule with Cron

To keep the cache warm, run the warmer periodically:

```bash
# Edit crontab
crontab -e

# Add one of these schedules:

# Every hour
0 * * * * /usr/bin/python3 /var/opt/scripts/varnish-setup/cache_warmer.py https://example.com >> /var/log/cache_warmer.log 2>&1

# Every 30 minutes
*/30 * * * * /usr/bin/python3 /var/opt/scripts/varnish-setup/cache_warmer.py https://example.com >> /var/log/cache_warmer.log 2>&1

# Daily at 3 AM
0 3 * * * /usr/bin/python3 /var/opt/scripts/varnish-setup/cache_warmer.py https://example.com >> /var/log/cache_warmer.log 2>&1
```

### Multi-Site Warming

Create a simple wrapper script to warm multiple sites:

```bash
#!/bin/bash
# /var/opt/scripts/warm_all_caches.sh

SITES=(
    "https://site1.com"
    "https://site2.com"
    "https://site3.com"
)

for site in "${SITES[@]}"; do
    echo "Warming cache for: $site"
    python3 /var/opt/scripts/varnish-setup/cache_warmer.py "$site"
    echo "---"
done
```

### WordPress Sitemap Requirements

The cache warmer works with standard WordPress sitemaps:

- **Yoast SEO**: Creates sitemap at `/sitemap_index.xml`
- **Rank Math**: Creates sitemap at `/sitemap_index.xml`  
- **Default WordPress**: Creates sitemap at `/wp-sitemap.xml` (WP 5.5+)
- **XML Sitemaps plugin**: Creates sitemap at `/sitemap.xml`

If your sitemap is at a non-standard location:
```bash
python3 cache_warmer.py --sitemap /my-sitemap.xml https://example.com
```

- [Varnish Documentation](https://varnish-cache.org/docs/)
- [Traefik Documentation](https://doc.traefik.io/traefik/)
- [VCL Examples](https://www.varnish-software.com/developers/tutorials/)

---

## 📄 License

This setup toolkit is provided as-is for use with your Traefik + WordPress infrastructure.
