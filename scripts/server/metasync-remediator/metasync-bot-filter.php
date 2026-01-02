<?php
/**
 * Plugin Name: MetaSync Bot Traffic Filter
 * Description: Prevent MetaSync OTTO from processing scanner/bot URLs
 * Version: 1.0
 */

// Prevent MetaSync OTTO from processing scanner/bot URLs
add_filter('metasync_otto_should_process_url', function($should_process, $url) {
    // Block common scanner/malicious paths
    $blocked_patterns = [
        '/alfa\.php',
        '/wp-blog\.php',
        '/wp-update\.php',
        '/cgi-bin/',
        '/\.php$/',  // Block direct PHP file access
    ];
    
    foreach ($blocked_patterns as $pattern) {
        if (preg_match($pattern, $url)) {
            return false;
        }
    }
    
    return $should_process;
}, 999, 2);
