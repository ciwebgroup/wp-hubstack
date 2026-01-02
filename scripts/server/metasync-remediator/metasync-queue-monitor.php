<?php
/**
 * Plugin Name: MetaSync Queue Monitor
 * Description: Monitor Action Scheduler queue health and alert on issues
 * Version: 1.0
 */

function metasync_queue_health_check() {
    global $wpdb;
    
    $pending = $wpdb->get_var("SELECT COUNT(*) FROM {$wpdb->prefix}actionscheduler_actions WHERE status = 'pending'");
    $failed = $wpdb->get_var("SELECT COUNT(*) FROM {$wpdb->prefix}actionscheduler_actions WHERE status = 'failed'");
    $stuck = $wpdb->get_var("SELECT COUNT(*) FROM {$wpdb->prefix}actionscheduler_claims WHERE claim_date_gmt < DATE_SUB(NOW(), INTERVAL 5 MINUTE)");
    
    if ($pending > 1000 || $failed > 100 || $stuck > 0) {
        error_log("MetaSync Queue Health Alert: Pending=$pending, Failed=$failed, Stuck=$stuck");
        // Send alert notification
        // You can add email/webhook notification here
    }
}
add_action('wp_loaded', 'metasync_queue_health_check');
