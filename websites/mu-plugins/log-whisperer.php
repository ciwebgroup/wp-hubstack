<?php
/**
 * Plugin Name: Log Whisperer (Introspective Hook Analysis)
 * Description: Analyzes what gets written to debug.log during specific WordPress hooks and manages log size for both debug and analysis logs.
 * Version: 1.2.0
 * Author: Maximillian Heth
 */

if (!defined('ABSPATH')) exit;

/**
 * The LogWhisperer class handles the introspection of the debug.log file.
 * It tracks the file size before and after a hook runs to isolate log entries
 * created by that specific hook, and manages file sizes to prevent disk overflow.
 */
class LogWhisperer {
    private $log_path;
    private $analysis_log_path;
    private $is_processing = false;
    private $max_log_size = 104857600; // 100MB in bytes
    private $excluded_hooks = [
        'all', 
        'plugins_loaded', 
        'gettext', 
        'gettext_with_context', 
        'attribute_escape'
    ];

    public function __construct() {
        $this->log_path = constant('WP_CONTENT_DIR') . '/debug.log';
        $this->analysis_log_path = constant('WP_CONTENT_DIR') . '/introspect_analysis.log';
        
        // 1. Perform Maintenance: Cap the size of both log files
        $this->enforce_log_size_cap($this->log_path, 'debug.log');
        $this->enforce_log_size_cap($this->analysis_log_path, 'introspect_analysis.log');

        // 2. Only run analysis if WP_DEBUG_LOG is enabled
        if (!defined('WP_DEBUG_LOG') || !WP_DEBUG_LOG) {
            return;
        }

        add_action('all', [$this, 'trace_hook']);
    }

    /**
     * Checks if a specific log file exceeds the maximum allowed size and deletes it if necessary.
     * * @param string $path Full path to the file.
     * @param string $label Human-readable name for reporting.
     */
    private function enforce_log_size_cap($path, $label) {
        if (file_exists($path)) {
            $current_size = filesize($path);

            if ($current_size >= $this->max_log_size) {
                // Delete the file to free up space
                unlink($path);
                
                // If we aren't deleting the analysis log itself, record the maintenance event
                if ($label !== 'introspect_analysis.log') {
                    $this->report_finding('SYSTEM_MAINTENANCE', "{$label} reached 100MB and was automatically deleted.");
                }
            }
        }
    }

    /**
     * The core logic that wraps every hook execution.
     */
    public function trace_hook($hook_name) {
        // Prevent infinite loops and skip noisy internal hooks
        if ($this->is_processing || in_array($hook_name, $this->excluded_hooks)) {
            return;
        }

        $this->is_processing = true;

        // REVISED STRATEGY: 
        // We log the hook name now, and then in the NEXT 'all' call, 
        // we check what was written since the PREVIOUS 'all' call.
        
        static $last_hook = null;
        static $last_size = 0;

        if ($last_hook !== null) {
            $current_size = file_exists($this->log_path) ? filesize($this->log_path) : 0;
            
            // If the size is smaller, the file was likely deleted/rotated
            if ($current_size > $last_size) {
                $this->analyze_diff($last_hook, $last_size, $current_size);
            }
        }

        $last_hook = $hook_name;
        $last_size = file_exists($this->log_path) ? filesize($this->log_path) : 0;

        $this->is_processing = false;
    }

    /**
     * Reads the portion of the log file that was just written.
     */
    private function analyze_diff($hook_name, $start, $end) {
        $length = $end - $start;
        if ($length <= 0) return;

        $handle = @fopen($this->log_path, 'rb');
        if (!$handle) return;

        fseek($handle, $start);
        $new_content = fread($handle, $length);
        fclose($handle);

        // Check if the content actually contains data
        if (trim($new_content)) {
            $this->report_finding($hook_name, $new_content);
        }
    }

    /**
     * Logic to handle the discovered log entry.
     */
    private function report_finding($hook, $content) {
        $timestamp = date('Y-m-d H:i:s');
        $report = "[{$timestamp}] [LogWhisperer] Hook: '{$hook}' triggered the following log entry:\n{$content}\n" . str_repeat('-', 30) . "\n";
        
        error_log($report, 3, $this->analysis_log_path);
    }
}

// Initialize the plugin
new LogWhisperer();