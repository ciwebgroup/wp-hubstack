vcl 4.1;

# =============================================================================
# BACKEND DEFINITION
# =============================================================================
backend wp_theadvisoryib {
    .host = "wp_theadvisoryib";
    .port = "80";
    .connect_timeout = 2s;
    .first_byte_timeout = 10s;
    .between_bytes_timeout = 5s;
}

# =============================================================================
# REQUEST HANDLING - Fast Cache Lookups
# =============================================================================
sub vcl_recv {
    # Set backend
    set req.backend_hint = wp_theadvisoryib;
    
    # Forward HTTPS protocol (Traefik terminates SSL)
    if (!req.http.X-Forwarded-Proto) {
        set req.http.X-Forwarded-Proto = "https";
    }
    
    # =========================================================================
    # BYPASS CACHE - Don't cache these requests
    # =========================================================================
    
    # Never cache admin, login, or authenticated requests
    if (req.url ~ "wp-admin|wp-login|wp-cron|xmlrpc\.php") {
        return (pass);
    }
    
    # Never cache POST requests
    if (req.method != "GET" && req.method != "HEAD") {
        return (pass);
    }
    
    # Never cache if user is logged in (WordPress/WooCommerce cookies)
    if (req.http.Cookie ~ "wordpress_logged_in|wordpress_sec_|wp-postpass_|woocommerce_cart|woocommerce_items_in_cart") {
        return (pass);
    }
    
    # Don't cache cart/checkout/account pages
    if (req.url ~ "cart|checkout|my-account|add-to-cart") {
        return (pass);
    }
    
    # =========================================================================
    # STATIC FILES - Cache aggressively for speed
    # =========================================================================
    if (req.url ~ "\.(css|js|jpg|jpeg|png|gif|ico|svg|woff|woff2|ttf|eot|webp|avif|mp4|webm|pdf)(\?.*)?$") {
        unset req.http.Cookie;
        return (hash);
    }
    
    # =========================================================================
    # COOKIE CLEANUP - Remove tracking cookies that don't affect content
    # =========================================================================
    # Remove analytics/tracking cookies so pages can be cached
    set req.http.Cookie = regsuball(req.http.Cookie, "(^|;\s*)(_ga|_gid|_gat|_fbp|_fbc|utm_[^=]+|__utm[a-z_]+)=[^;]+", "");
    set req.http.Cookie = regsuball(req.http.Cookie, "(^|;\s*)(has_js|__cfduid|__hssc|__hssrc|__hstc)=[^;]+", "");
    
    # Clean up empty cookies
    set req.http.Cookie = regsuball(req.http.Cookie, "^;\s*", "");
    set req.http.Cookie = regsuball(req.http.Cookie, ";\s*;", ";");
    if (req.http.Cookie == "" || req.http.Cookie ~ "^\s*$") {
        unset req.http.Cookie;
    }
    
    # Default: try to cache
    return (hash);
}

# =============================================================================
# BACKEND RESPONSE - Set Cache TTLs
# =============================================================================
sub vcl_backend_response {
    # Don't cache errors
    if (beresp.status >= 500) {
        set beresp.uncacheable = true;
        return (deliver);
    }
    
    # Static files: cache for 30 days
    if (bereq.url ~ "\.(css|js|jpg|jpeg|png|gif|ico|svg|woff|woff2|ttf|eot|webp|avif|mp4|webm|pdf)(\?.*)?$") {
        unset beresp.http.Set-Cookie;
        set beresp.ttl = 30d;
        set beresp.http.Cache-Control = "public, max-age=2592000";
        return (deliver);
    }
    
    # HTML pages: cache for 10 minutes (adjust based on update frequency)
    if (beresp.http.Content-Type ~ "text/html") {
        set beresp.ttl = 10m;
        set beresp.http.Cache-Control = "public, max-age=600";
        return (deliver);
    }
    
    # Respect backend cache headers if present
    if (beresp.http.Cache-Control) {
        return (deliver);
    }
    
    # Default: cache for 5 minutes
    set beresp.ttl = 5m;
    set beresp.http.Cache-Control = "public, max-age=300";
    
    return (deliver);
}

# =============================================================================
# CACHE HIT - Deliver cached content
# =============================================================================
sub vcl_hit {
    # If cached object is still fresh, deliver it
    if (obj.ttl >= 0s) {
        return (deliver);
    }
    
    # If stale, fetch new version
    return (restart);
}

# =============================================================================
# RESPONSE DELIVERY - Add debug headers
# =============================================================================
sub vcl_deliver {
    # Add cache status header for debugging
    if (obj.hits > 0) {
        set resp.http.X-Cache = "HIT";
        set resp.http.X-Cache-Hits = obj.hits;
    } else {
        set resp.http.X-Cache = "MISS";
    }
    
    # Remove Varnish internal headers
    unset resp.http.Via;
    unset resp.http.X-Varnish;
    
    return (deliver);
}
