<?php
/**
 * Plugin Name: Custom Roles
 * Description: Automatically creates and assigns capabilities to custom roles.
 * Version: 1.0
 * Author: CI Web Group
 */

if (!defined('ABSPATH')) {
    exit; // Exit if accessed directly.
}

define( 'OIDC_LOGIN_TYPE', 'button');
define( 'OIDC_CLIENT_ID', 'ytw09zJn8gfcZedq0nQRpWKSWmLfAM1VglNzknN1');
define( 'OIDC_CLIENT_SECRET', '83bLYavblUuGwGGvIlpuAMJpUluoPBGRJIfKYHAfW8FbeCRU9Y621q8ohYOWtuGpixjTGXdfnk7n61JwVDp5CZNbdhneWhvQGfAssIYCwq21KFKKrkIRcyXe11ZiepYZ');
define( 'OIDC_CLIENT_SCOPE', 'openid email profile offline_access');
define( 'OIDC_ENDPOINT_LOGIN_URL', 'https://sso.ciwgserver.com/application/o/authorize/');
define( 'OIDC_ENDPOINT_USERINFO_URL', 'https://sso.ciwgserver.com/application/o/userinfo/');
define( 'OIDC_ENDPOINT_TOKEN_URL', 'https://sso.ciwgserver.com/application/o/token/');
define( 'OIDC_ENDPOINT_LOGOUT_URL', 'https://sso.ciwgserver.com/application/o/wordpress-sso/end-session/');
define( 'OIDC_ACR_VALUES', '');
define( 'OIDC_ENFORCE_PRIVACY', 0);
define( 'OIDC_LINK_EXISTING_USERS', 1);
define( 'OIDC_CREATE_IF_DOES_NOT_EXIST', 1);
define( 'OIDC_REDIRECT_USER_BACK', 1);
define( 'OIDC_REDIRECT_ON_LOGOUT', 0);
define( 'OIDC_ENABLE_LOGGING', 1);
define( 'OIDC_LOG_LIMIT', 1000);
define( 'OIDC_RESPONSE_TYPE', 'code');

require_once dirname(__FILE__) . '/openid-connect/openid-connect-generic.php';

add_action( 'admin_init', function () {
    global $pagenow;
	$user = wp_get_current_user();

    // Check if the current page is the Users page.
    if ( 'users.php' === $pagenow && !$user->has_cap('server_admin') ) {
		wp_die( __( 'You do not have sufficient permissions to access this page.' ) );
        wp_redirect( admin_url() );
        exit;
    }
});

add_filter( 'openid-connect-generic-login-button-text', function() {
	return 'Login with CI Connect';
});

add_filter( 'login_headertext', function() {
    return 'CI CONNECT';
});

add_action( 'login_enqueue_scripts', function() { ?>
    <style type="text/css">
		html body {
			background: #202020;
		}
		#login form {
			border-radius: 5px;
		}
		#login .button:focus,
		#login .button-secondary:focus,
		#login .button-primary:focus {
			border: 0 none;
			box-shadow: none;
		}
		#login .button,
		#login .button-secondary,
		#login .button-primary {
			background-color: #f92c0f;
			border: 0 none;
			color: #f7f7f7;
		}
		#login .button:hover,
		#login .button-secondary:hover,
		#login .button-primary:hover {
			background-color: #c11f08;
		}
		#login input[type="text"]:focus,
		#login input[type="password"]:focus,
		#login input[type="color"]:focus,
		#login input[type="date"]:focus,
		#login input[type="datetime"]:focus,
		#login input[type="datetime-local"]:focus,
		#login input[type="email"]:focus,
		#login input[type="month"]:focus,
		#login input[type="number"]:focus,
		#login input[type="search"]:focus,
		#login input[type="tel"]:focus,
		#login input[type="time"]:focus,
		#login input[type="url"]:focus,
		#login input[type="week"]:focus,
		#login input[type="checkbox"]:focus,
		#login input[type="radio"]:focus,
		#login select:focus,
		#login textarea:focus {
			border-color: #f92c0f;
			box-shadow: 0 0 1px #f92c0f;
		}
        #login h1 a {
            background-image: url(https://www.ciwebgroup.com/wp-content/uploads/2025/02/logo-2.png);
			height: 42px;
			width: 320px;
			background-size: 320px auto;
			background-repeat: no-repeat;
        	padding-bottom: 15px;
        }
    </style>
<?php });

add_action('admin_init', 'register_roles');
function register_roles () {
    if ( ! ( $admin = get_role('administrator') ) ){
        return;
    }
    if ( ! $admin->capabilities ){
        return;
    }

    /**
     * Cap Groups:
	*/
	$gravity_caps = [
		'gravityforms_create_form', 'gravityforms_delete_forms', 'gravityforms_edit_forms', 'gravityforms_preview_forms', 'gravityforms_view_entries', 'gravityforms_edit_entries',
		'gravityforms_delete_entries', 'gravityforms_view_entry_notes', 'gravityforms_edit_entry_notes', 'gravityforms_export_entries', 'gravityforms_view_settings', 'gravityforms_edit_settings',
		'gravityforms_view_updates', 'gravityforms_view_addons', 'gravityforms_system_status', 'gravityforms_uninstall', 'gravityforms_logging', 'gravityforms_api_settings'
	];

	$rankmath_caps = [
		'rank_math_404_monitor', 'rank_math_admin_bar', 'rank_math_sitemap', 'rank_math_titles',
		'rank_math_analytics', 'rank_math_content_ai', 'rank_math_edit_htaccess', 'rank_math_general', 'rank_math_link_builder', 'rank_math_onpage_advanced', 'rank_math_onpage_analysis',
		'rank_math_onpage_general', 'rank_math_onpage_snippet', 'rank_math_onpage_social', 'rank_math_rank_math_site_analysis', 'rank_math_redirections', 'rank_math_site_analysis'
	];

    $roles = [
        'wp_asset_guardian' => [
            'name' => 'WP Asset Guardian',
            'capabilities' => array_keys(get_role('administrator')->capabilities)
        ],
        'server_admin' => [
            'name' => 'Server Admin',
            'capabilities' => array_merge([ 'server_admin' ], array_keys(get_role('administrator')->capabilities), $gravity_caps, $rankmath_caps, ['view_stream'] )
        ],
        'super_team' => [
            'name' => 'Super Team',
            'capabilities' => array_merge([ 'server_admin' ], array_keys(get_role('administrator')->capabilities), $gravity_caps, $rankmath_caps, ['view_stream'] )
		],
        'helpdesk' => [
            'name' => 'Helpdesk',
            'capabilities' => array_merge([ 'helpdesk' ], array_keys(get_role('administrator')->capabilities), $gravity_caps, $rankmath_caps, ['view_stream'] )
        ],
        'customer' => [
            'name' => 'Customer',
            'capabilities' => array_merge([
                'seo', 'activate_plugins', 'delete_plugins', 'edit_plugins', 'manage_links', 'edit_others_posts',
                'edit_pages', 'edit_others_pages', 'edit_published_pages', 'publish_pages', 'delete_pages',
                'delete_others_pages', 'delete_published_pages', 'delete_others_posts', 'upload_files', 'publish_posts',
                'delete_published_posts', 'edit_posts', 'delete_posts', 'read', 'manage_options', 
			], $gravity_caps)
		],
        'content' => [
            'name' => 'Content',
            'capabilities' => array_merge([
                'content', 'export', 'import', 'moderate_comments', 'manage_categories', 'manage_links', 'edit_others_posts',
                'edit_pages','edit_others_pages', 'edit_published_pages', 'publish_pages', 'delete_pages', 'delete_others_pages',
                'delete_published_pages', 'delete_others_posts', 'delete_private_posts', 'edit_private_posts', 'read_private_posts',
                'delete_private_pages', 'edit_private_pages', 'read_private_pages', 'edit_published_posts', 'publish_posts',
                'delete_published_posts', 'edit_posts', 'delete_posts', 'upload_files', 'read',
			], $gravity_caps, $rankmath_caps, ['view_stream'] )
        ],
        'seo' => [
            'name' => 'SEO',
            'capabilities' => array_merge([
                'seo', 'activate_plugins', 'delete_plugins', 'edit_plugins', 'manage_links', 'edit_others_posts',
                'edit_pages', 'edit_others_pages', 'edit_published_pages', 'publish_pages', 'delete_pages',
                'delete_others_pages', 'delete_published_pages', 'delete_others_posts', 'upload_files', 'publish_posts',
                'delete_published_posts', 'edit_posts', 'delete_posts', 'read', 'manage_options', 
			], $gravity_caps, $rankmath_caps, ['view_stream'] )
        ],
        'nearby_now' => [
            'name' => 'Nearby Now',
            'capabilities' => [
                'nearby_now', 'export', 'import', 'moderate_comments', 'manage_categories', 'manage_links', 'edit_others_posts', 'edit_pages',
                'edit_pages', 'edit_others_pages', 'edit_published_pages', 'publish_pages', 'delete_pages', 'delete_others_pages',
                'delete_published_pages', 'delete_others_posts', 'delete_private_posts', 'edit_private_posts', 'read_private_posts',
                'delete_private_pages', 'edit_private_pages', 'read_private_pages', 'edit_published_posts', 'publish_posts',
                'delete_published_posts', 'edit_posts', 'delete_posts', 'read', 'view_stream'
            ],
        ],
        'web_production' => [
            'name' => 'Web Production',
            'capabilities' => array_merge([
                'web_production', 'edit_files', 'edit_theme_options', 'edit_themes', 'export', 'import', 'install_plugins', 'install_themes',
                'switch_themes', 'edit_dashboard', 'customize', 'delete_site', 'edit_pages', 'edit_others_pages',
                'edit_published_pages', 'publish_pages', 'delete_pages', 'delete_others_pages', 'delete_published_pages',
                'delete_others_posts', 'delete_private_posts', 'edit_private_posts', 'read_private_posts', 'delete_private_pages',
                'edit_private_pages', 'read_private_pages', 'unfiltered_html', 'edit_published_posts', 'upload_files',
                'publish_posts', 'delete_published_posts', 'edit_posts', 'delete_posts', 'read', 'view_stream'
			], $gravity_caps, $rankmath_caps)
        ],
        'qa' => [
            'name' => 'QA',
            'capabilities' => ['qa', 'read', 'edit_posts', 'edit_pages', 'view_stream'],
        ],
    ];

    foreach ($roles as $role_key => $role_data) {
        if (!get_role($role_key)) {
            add_role($role_key, $role_data['name'], array_fill_keys($role_data['capabilities'], true));
        } else {
            $role = get_role($role_key);
            foreach ($role_data['capabilities'] as $cap) {
                $role->add_cap($cap);
            }
        }
    }

    // Strip asset management capabilities from all roles except wp_asset_guardian.
    $restricted_caps = [
        'install_plugins',
        'delete_plugins',
        'install_themes',
        'delete_themes',
    ];

    $all_roles = wp_roles()->roles;
    foreach (array_keys($all_roles) as $role_name) {
        if ($role_name !== 'wp_asset_guardian') {
            $role = get_role($role_name);
            if ($role) {
                foreach ($restricted_caps as $cap) {
                    $role->remove_cap($cap);
                }
            }
        }
    }
}
