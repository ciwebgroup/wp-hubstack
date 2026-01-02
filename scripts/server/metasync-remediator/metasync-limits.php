<?php
/**
 * Plugin Name: MetaSync Resource Limits
 * Description: Prevents MetaSync from exhausting CPU resources
 * Version: 1.0
 */

// Limit Action Scheduler batch size
add_filter('action_scheduler_queue_runner_batch_size', function($batch_size) {
    return 10; // Reduce from default 25-50
}, 10, 1);

// Limit concurrent queue runners (CRITICAL)
add_filter('action_scheduler_maximum_concurrent_batches', function($max) {
    return 1; // Only allow 1 concurrent batch
}, 10, 1);

// Reduce Action Scheduler execution time
add_filter('action_scheduler_queue_runner_time_limit', function($time_limit) {
    return 20; // Reduce from default 30 seconds
}, 10, 1);

// Limit MetaSync log processing batch size
add_filter('metasync_log_batch_size', function($batch_size) {
    return 500; // Reduce from 1000
}, 10, 1);

// Limit MetaSync execution time
add_filter('metasync_log_max_execution_time', function($time) {
    return 20; // Reduce from 30 seconds
}, 10, 1);

// Reduce OTTO API rate limit
add_filter('metasync_otto_max_api_calls_per_minute', function() {
    return 5; // Reduce from 10
}, 999);

// Prevent OTTO from processing non-existent URLs (404s)
add_filter('metasync_otto_should_process_url', function($should_process, $url) {
    // Skip processing if URL returns 404
    $response = wp_remote_head($url, array('timeout' => 2));
    if (is_wp_error($response) || wp_remote_retrieve_response_code($response) === 404) {
        return false;
    }
    return $should_process;
}, 10, 2);
