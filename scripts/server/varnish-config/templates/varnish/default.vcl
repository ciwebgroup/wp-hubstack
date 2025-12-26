vcl 4.1;
# =============================================================================
# VARNISH VCL TEMPLATE FOR WORDPRESS
# =============================================================================
# This is a template file. Replace the placeholder values before use.
#
# Placeholders:
#   {{BACKEND_NAME}}     - Name for the backend (e.g., wp_mysite)
#   {{CONTAINER_NAME}}   - Docker container name
#   {{HOSTNAME}}         - Site hostname (e.g., mysite.com)
# =============================================================================

import std;
import directors;

# =============================================================================
# BACKEND DEFINITIONS
# =============================================================================
# Add a backend for each WordPress site

backend {{BACKEND_NAME}} {
    .host = "{{CONTAINER_NAME}}";
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
        # WordPress redirects HTTP to HTTPS, so expect 301
        .expected_response = 301;
    }
}

# Add more backends as needed:
# backend wp_anothersite {
#     .host = "wp_anothersite";
#     .port = "80";
#     ...
# }

# ACL for purge/admin requests
acl purge {
    "localhost";
    "127.0.0.1";
    "172.16.0.0"/12;
    "10.0.0.0"/8;
}

# =============================================================================
# INITIALIZATION
# =============================================================================
sub vcl_init {
    new wordpress = directors.round_robin();
    wordpress.add_backend({{BACKEND_NAME}});
    # wordpress.add_backend(wp_anothersite);
}

# =============================================================================
# REQUEST HANDLING
# =============================================================================
sub vcl_recv {
    # Route to correct backend based on Host header
    if (req.http.host ~ "{{HOSTNAME}}") {
        set req.backend_hint = {{BACKEND_NAME}};
    }
    # Add more host-based routing:
    # else if (req.http.host ~ "anothersite") {
    #     set req.backend_hint = wp_anothersite;
    # }
    else {
        set req.backend_hint = {{BACKEND_NAME}};
    }
    
    # Ensure X-Forwarded-Proto is set (Traefik terminates SSL)
    if (!req.http.X-Forwarded-Proto) {
        set req.http.X-Forwarded-Proto = "https";
    }
    
    # Handle purge requests
    if (req.method == "PURGE") {
        if (!client.ip ~ purge) {
            return (synth(405, "Method not allowed"));
        }
        return (purge);
    }
    
    # Handle BAN requests
    if (req.method == "BAN") {
        if (!client.ip ~ purge) {
            return (synth(405, "Method not allowed"));
        }
        ban("req.http.host == " + req.http.host + " && req.url ~ " + req.url);
        return (synth(200, "Banned"));
    }
    
    # Normalize host header
    if (req.http.host) {
        set req.http.host = regsub(req.http.host, "^www\.", "");
        set req.http.host = regsub(req.http.host, ":[0-9]+", "");
    }
    
    # =========================================================================
    # WORDPRESS-SPECIFIC RULES
    # =========================================================================
    
    # Never cache admin, login, cron
    if (req.url ~ "wp-admin|wp-login|wp-cron|xmlrpc\.php|preview=true") {
        return (pass);
    }
    
    # Never cache POST requests
    if (req.method == "POST") {
        return (pass);
    }
    
    # Never cache if logged in
    if (req.http.Cookie ~ "wordpress_logged_in|wordpress_sec_|wp-postpass_|comment_author_") {
        return (pass);
    }
    
    # Don't cache cart/checkout (WooCommerce)
    if (req.url ~ "cart|checkout|my-account|add-to-cart|logout") {
        return (pass);
    }
    
    # Static files - always cache
    if (req.url ~ "\.(css|js|jpg|jpeg|png|gif|ico|svg|woff|woff2|ttf|eot|webp|avif|mp4|webm|pdf)(\?.*)?$") {
        unset req.http.Cookie;
        return (hash);
    }
    
    # Remove tracking cookies
    set req.http.Cookie = regsuball(req.http.Cookie, "utm[a-z_]+=[^;]+(; )?", "");
    set req.http.Cookie = regsuball(req.http.Cookie, "_ga[^=]*=[^;]+(; )?", "");
    set req.http.Cookie = regsuball(req.http.Cookie, "_gid=[^;]+(; )?", "");
    set req.http.Cookie = regsuball(req.http.Cookie, "_fbp=[^;]+(; )?", "");
    
    # Clean up empty cookies
    if (req.http.Cookie == "" || req.http.Cookie ~ "^\s*$") {
        unset req.http.Cookie;
    }
    
    return (hash);
}

# =============================================================================
# BACKEND RESPONSE HANDLING
# =============================================================================
sub vcl_backend_response {
    # =========================================================================
    # STALE-IF-ERROR / GRACE MODE
    # =========================================================================
    
    # Grace: Serve stale while refreshing in background (24 hours)
    set beresp.grace = 24h;
    
    # Keep: Serve stale when backend is DOWN (7 days) - TRUE STALE-IF-ERROR
    set beresp.keep = 7d;
    
    # =========================================================================
    
    # Don't cache 5xx errors
    if (beresp.status >= 500 && beresp.status < 600) {
        if (bereq.is_bgfetch) {
            return (abandon);
        }
        set beresp.ttl = 0s;
        set beresp.uncacheable = true;
        return (deliver);
    }
    
    # Handle redirects
    if (beresp.status == 301 || beresp.status == 302) {
        set beresp.ttl = 1h;
        set beresp.grace = 1h;
        return (deliver);
    }
    
    # Override WordPress max-age=0 for anonymous users
    if (beresp.http.Cache-Control ~ "max-age=0" || !beresp.http.Cache-Control) {
        if (beresp.http.Cache-Control !~ "no-store|private") {
            set beresp.ttl = 5m;
        }
    }
    
    # Static files: cache longer
    if (bereq.url ~ "\.(css|js|jpg|jpeg|png|gif|ico|svg|woff|woff2|webp|avif)(\?.*)?$") {
        unset beresp.http.Set-Cookie;
        set beresp.ttl = 7d;
        set beresp.grace = 1d;
    }
    
    # Remove security-sensitive headers
    unset beresp.http.Server;
    unset beresp.http.X-Powered-By;
    
    return (deliver);
}

# =============================================================================
# CACHE HIT HANDLING
# =============================================================================
sub vcl_hit {
    # Fresh content: deliver
    if (obj.ttl >= 0s) {
        return (deliver);
    }
    
    # Within grace period: deliver stale, refresh in background
    if (obj.ttl + obj.grace > 0s) {
        return (deliver);
    }
    
    # Within keep period AND backend is down: deliver stale (stale-if-error!)
    if (obj.ttl + obj.grace + obj.keep > 0s) {
        if (!std.healthy(req.backend_hint)) {
            set req.http.X-Varnish-Grace = "stale-if-error";
            return (deliver);
        }
    }
    
    return (restart);
}

# =============================================================================
# RESPONSE DELIVERY
# =============================================================================
sub vcl_deliver {
    # Add cache status headers
    if (obj.hits > 0) {
        set resp.http.X-Cache = "HIT";
        set resp.http.X-Cache-Hits = obj.hits;
    } else {
        set resp.http.X-Cache = "MISS";
    }
    
    # Indicate stale content
    if (req.http.X-Varnish-Grace) {
        set resp.http.X-Cache = "STALE-IF-ERROR";
    } else if (obj.ttl < 0s) {
        set resp.http.X-Cache = "STALE-GRACE";
    }
    
    set resp.http.X-Cache-Backend = "Varnish-7.6";
    
    # Cleanup internal headers
    unset resp.http.Via;
    unset resp.http.X-Varnish;
    
    return (deliver);
}

# =============================================================================
# BACKEND ERROR
# =============================================================================
sub vcl_backend_error {
    set beresp.http.Content-Type = "text/html; charset=utf-8";
    set beresp.http.Retry-After = "60";
    
    synthetic({"<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Temporarily Unavailable</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, sans-serif;
            display: flex; justify-content: center; align-items: center;
            min-height: 100vh; margin: 0;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
        }
        .container {
            text-align: center; padding: 3rem; background: white;
            border-radius: 16px; box-shadow: 0 25px 50px rgba(0,0,0,0.25);
            max-width: 500px; margin: 1rem;
        }
        h1 { color: #1a1a2e; } p { color: #666; }
    </style>
</head>
<body>
    <div class="container">
        <h1>We'll be right back</h1>
        <p>We're performing some maintenance. Please try again shortly.</p>
    </div>
</body>
</html>"});
    
    return (deliver);
}
