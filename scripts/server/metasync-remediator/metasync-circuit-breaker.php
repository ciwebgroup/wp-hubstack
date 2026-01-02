<?php
/**
 * Emergency Circuit Breaker for MetaSync
 * 
 * Add this to wp-config.php or as a mu-plugin to temporarily disable 
 * MetaSync features during CPU exhaustion incidents.
 * 
 * Usage: Copy to wp-content/mu-plugins/ or add defines to wp-config.php
 */

// Emergency: Disable MetaSync background processing
if (!defined('METASYNC_DISABLE_OTTO')) {
    define('METASYNC_DISABLE_OTTO', true);
}

if (!defined('METASYNC_DISABLE_LOG_SYNC')) {
    define('METASYNC_DISABLE_LOG_SYNC', true);
}

// Pause Action Scheduler processing
add_filter('action_scheduler_run_queue', '__return_false', 999);
