<?php
/**
 * Plugin Name:       Block Specific File Manager Plugins
 * Description:       Prevents the installation and activation of a specific list of file manager, media library, and download manager plugins for security and performance reasons. This is a Must-Use plugin.
 * Version:           1.1
 * Author:            Maximillian Heth
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit; // Exit if accessed directly.
}

/**
 * Main class to handle the plugin blocking logic.
 */
class Block_Specific_Plugins {

	/**
	 * A list of banned plugin slugs. Used to block new installations.
	 * The slug is typically the directory name of the plugin.
	 *
	 * @var array
	 */
	private $banned_slugs = [
        //'send-images-rss',
        //'tiled-gallery-carousel-without-jetpack',
		'wp-file-manager',
		'file-manager-advanced',
		'filester', // Slug for Filester - File Manager Pro
		'wpide',
		'filebird',
		'real-media-library-lite',
		'folders',
		'happyfiles-lite',
		'download-manager',
		'download-monitor',
		'nmedia-user-file-uploader', // Slug for Frontend File Manager Plugin
		'shared-files', // Slug for Shared Files - File Upload & Download Manager
	];

	/**
	 * A list of banned plugin basenames (e.g., 'slug/plugin-file.php').
	 * Used to check for and deactivate already installed plugins.
	 *
	 * @var array
	 */
	private $banned_basenames = [
		'wp-file-manager/file_folder_manager.php',
		'file-manager-advanced/file_manager_advanced.php',
		'filester/ninja-file-manager.php',
		'wpide/wpide.php',
		'filebird/filebird.php',
		'real-media-library-lite/index.php',
		'folders/folders.php',
		'catfolders/catfolders.php',
		'happyfiles-lite/happyfiles-lite.php',
		'download-manager/download-manager.php',
		'download-monitor/download-monitor.php',
		'nmedia-user-file-uploader/wp-file-manager.php',
		'shared-files/shared-files.php',
	];

	/**
	 * Constructor to hook into WordPress actions and filters.
	 */
	public function __construct() {
		// Hook to prevent installation of banned plugins from WordPress.org or ZIP upload.
		add_filter( 'upgrader_pre_install', [ $this, 'prevent_plugin_install' ], 10, 2 );

		// Hook to prevent activation of an already installed banned plugin. Fires immediately.
		add_action( 'activated_plugin', [ $this, 'prevent_plugin_activation' ], 10, 1 );

		// Fallback hook to check for and deactivate banned plugins if they are already installed.
		add_action( 'admin_init', [ $this, 'deactivate_banned_plugins' ] );

		// Hook to show a persistent admin notice after a banned plugin is deactivated.
		add_action( 'admin_notices', [ $this, 'show_deactivation_notice' ] );
	}

	/**
	 * Prevents the installation of plugins from the banned list.
	 *
	 * @param bool|WP_Error $response The installation response.
	 * @param array         $options  Array of extra arguments passed to the upgrader.
	 * @return bool|WP_Error A WP_Error object if the plugin is banned, otherwise the original response.
	 */
	public function prevent_plugin_install( $response, $options ) {
		// Check if we are installing a plugin and have the necessary info.
		if ( isset( $options['type'] ) && $options['type'] === 'plugin' && ! empty( $options['plugin'] ) ) {
			$plugin_slug = $options['plugin'];

			// For zip uploads, the slug might be in a 'plugin-name/plugin.php' format.
			// We extract just the directory name to match our slug list.
			if ( strpos( $plugin_slug, '/' ) !== false ) {
				$plugin_slug = dirname( $plugin_slug );
			}

			if ( in_array( $plugin_slug, $this->banned_slugs, true ) ) {
				return new WP_Error(
					'plugin_installation_banned',
					'<strong>Installation Failed:</strong> This plugin is not permitted on this website. Plugins that offer direct file system access are restricted for security reasons.'
				);
			}
		}
		return $response;
	}

	/**
	 * Prevents the activation of a banned plugin and provides immediate feedback.
	 * This triggers right after a user clicks 'Activate'.
	 *
	 * @param string $plugin_basename The basename of the plugin that was just activated.
	 */
	public function prevent_plugin_activation( $plugin_basename ) {
		if ( in_array( $plugin_basename, $this->banned_basenames, true ) ) {
			// Ensure deactivation functions are available.
			if ( ! function_exists( 'deactivate_plugins' ) ) {
				include_once ABSPATH . 'wp-admin/includes/plugin.php';
			}

			// Deactivate the plugin immediately.
			deactivate_plugins( $plugin_basename, true );

			// Redirect back to the plugins page with an error query argument for our notice.
			$redirect_url = add_query_arg(
				[
					'banned_plugin_activated' => 'true',
					'plugin_name'             => urlencode( $plugin_basename ),
				],
				self_admin_url( 'plugins.php' )
			);
			wp_safe_redirect( $redirect_url );
			exit;
		}
	}


	/**
	 * Checks for active banned plugins and deactivates them. This is a fallback.
	 */
	public function deactivate_banned_plugins() {
		// Ensure the is_plugin_active() and deactivate_plugins() functions are available.
		if ( ! function_exists( 'is_plugin_active' ) ) {
			include_once ABSPATH . 'wp-admin/includes/plugin.php';
		}

		$deactivated_plugins = [];
		foreach ( $this->banned_basenames as $plugin_basename ) {
			if ( is_plugin_active( $plugin_basename ) ) {
				// Deactivate silently and store the basename to show a single notice.
				deactivate_plugins( $plugin_basename, true );
				$deactivated_plugins[] = $plugin_basename;
			}
		}

		// If we deactivated any plugins, set a short-lived transient to show an admin notice.
		if ( ! empty( $deactivated_plugins ) ) {
			set_transient( 'banned_plugins_deactivated_notice', $deactivated_plugins, 60 );
		}
	}

	/**
	 * Displays an admin notice if a banned plugin was automatically deactivated.
	 */
	public function show_deactivation_notice() {
		$message = '';

		// Case 1: Notice for the immediate activation block (from redirect).
		if ( isset( $_GET['banned_plugin_activated'] ) && ! empty( $_GET['plugin_name'] ) ) {
			$plugin_basename = urldecode( wp_unslash( $_GET['plugin_name'] ) );
			$plugin_data     = get_plugin_data( WP_PLUGIN_DIR . '/' . $plugin_basename );
			$plugin_name     = '<strong>' . esc_html( $plugin_data['Name'] ) . '</strong>';
			$message         = sprintf(
				'The plugin %s was not activated because it is on the restricted list. This is a security measure.',
				$plugin_name
			);
		} else {
			// Case 2: Notice for the fallback deactivation on page load.
			$deactivated_plugins = get_transient( 'banned_plugins_deactivated_notice' );
			if ( $deactivated_plugins ) {
				$plugin_names = [];
				foreach ( $deactivated_plugins as $plugin_basename ) {
					$plugin_data    = get_plugin_data( WP_PLUGIN_DIR . '/' . $plugin_basename );
					$plugin_names[] = '<strong>' . esc_html( $plugin_data['Name'] ) . '</strong>';
				}
				$message = sprintf(
					'The following plugin(s) were automatically deactivated because they are not permitted on this site: %s. This is a security measure.',
					implode( ', ', $plugin_names )
				);
				delete_transient( 'banned_plugins_deactivated_notice' );
			}
		}

		if ( ! empty( $message ) ) {
			printf( '<div class="notice notice-error is-dismissible"><p>%s</p></div>', wp_kses_post( $message ) );
		}
	}
}

// Instantiate the class to run the plugin.
new Block_Specific_Plugins();

