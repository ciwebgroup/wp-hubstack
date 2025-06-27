#!/usr/bin/env python3
"""
Processes a Google Sheet to cancel WordPress hosting for specified websites.

This script reads URLs from a Google Sheet, processes site cancellations
(deactivating plugins, removing licenses, creating archives), and logs
the results to another worksheet.
"""

import os
import sys
import subprocess
import argparse
import logging
import shutil
import secrets
import string
from urllib.parse import urlparse
from datetime import datetime

import gspread
from oauth2client.service_account import ServiceAccountCredentials

# --- Configuration ---
DEFAULT_LOG_FILE = '~/logs/cancellation-processing.log'  
DEFAULT_BASE_DIR = '/var/opt'
DEFAULT_SHEET_NAME = 'Sites To Be Canceled'
DEFAULT_URL_COLUMN = 'URL'
DEFAULT_EMAIL_COLUMN = 'Email'
DEFAULT_LOG_SHEET_NAME = 'Log'
DEFAULT_FALLBACK_ADMIN_EMAIL = 'domain@ciwebgroup.com'

# WordPress options to remove during cancellation
OPTIONS_TO_REMOVE = [
    "license_number",
    "_elementor_pro_license_data", 
    "_elementor_pro_license_data_fallback",
    "_elementor_pro_license_v2_data_fallback",
    "_elementor_pro_license_v2_data",
    "_transient_timeout_rg_gforms_license",
    "_transient_rg_gforms_license", 
    "_transient_timeout_uael_license_status",
    "_transient_timeout_astra-addon_license_status",
]

def setup_logging():
    """Set up basic logging."""
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s - %(levelname)s - %(message)s',
        stream=sys.stdout
    )

def get_spreadsheet(spreadsheet_id: str, credentials_file: str) -> gspread.Spreadsheet | None:
    """
    Authorize with Google and return the spreadsheet object.
    """
    try:
        logging.info(f"Authorizing with Google using '{credentials_file}'...")
        scope = ['https://spreadsheets.google.com/feeds', 'https://www.googleapis.com/auth/drive']
        creds = ServiceAccountCredentials.from_json_keyfile_name(credentials_file, scope)
        client = gspread.authorize(creds)
        
        logging.info(f"Opening spreadsheet with ID: {spreadsheet_id}")
        spreadsheet = client.open_by_key(spreadsheet_id)
        return spreadsheet
        
    except gspread.exceptions.SpreadsheetNotFound:
        logging.error(f"Error: Spreadsheet with ID '{spreadsheet_id}' not found or access denied.")
        return None
    except gspread.exceptions.WorksheetNotFound:
        logging.error(f"Error: Worksheet not found in the spreadsheet.")
        return None
    except FileNotFoundError:
        logging.error(f"Error: Credentials file not found at '{credentials_file}'")
        return None
    except Exception as e:
        logging.error(f"An unexpected error occurred during Google Sheets setup: {e}")
        return None

def generate_password(length: int = 12) -> str:
    """Generate a random password."""
    alphabet = string.ascii_letters + string.digits
    return ''.join(secrets.choice(alphabet) for _ in range(length))

def run_wp_command(container_name: str, wp_args: list) -> subprocess.CompletedProcess:
    """Run wp-cli command inside Docker container."""
    cmd = ['docker', 'exec', '-i', container_name, 'wp'] + wp_args + ['--skip-themes', '--quiet']
    return subprocess.run(cmd, capture_output=True, text=True, check=True)

def check_dependencies():
    """Check if required system dependencies are available."""
    if not shutil.which('zip'):
        logging.error("Error: 'zip' is not installed. Please install it using: apt-get install zip")
        return False
    if not shutil.which('docker'):
        logging.error("Error: 'docker' is not installed or not in PATH.")
        return False
    return True

def container_exists(container_name: str) -> bool:
    """Check if Docker container exists and is running."""
    try:
        result = subprocess.run(['docker', 'ps', '--format', '{{.Names}}'], 
                              capture_output=True, text=True, check=True)
        return container_name in result.stdout.splitlines()
    except subprocess.CalledProcessError:
        return False

def cancel_wordpress_site(full_domain: str, base_dir: str, admin_email: str, dry_run: bool = False) -> dict:
    """
    Cancel a WordPress site by processing plugins, licenses, and creating archive.
    
    Returns a dict with status info including:
    - success: bool
    - zip_url: str (if successful)  
    - admin_email: str
    - admin_password: str (if successful)
    - error: str (if failed)
    """
    result = {
        'success': False,
        'zip_url': '',
        'admin_email': admin_email,
        'admin_password': '',
        'error': ''
    }
    
    try:
        # Parse domain and setup paths
        base_domain = full_domain.replace('.', '').replace('-', '')
        container_name = f"wp_{base_domain}"
        site_dir = os.path.join(base_dir, full_domain)
        zip_file = f"{site_dir}.zip"
        wp_content_dir = os.path.join(site_dir, 'www', 'wp-content')
        
        logging.info(f"Processing cancellation for domain: {full_domain}")
        logging.info(f"Container name: {container_name}")
        logging.info(f"Site directory: {site_dir}")
        
        if dry_run:
            logging.info(f"[DRY RUN] Would process cancellation for {full_domain}")
            result['success'] = True
            result['zip_url'] = f"https://{full_domain}/wp-content/{full_domain}.zip"
            result['admin_password'] = "DRY_RUN_PASSWORD"
            return result
        
        # Verify site directory exists
        if not os.path.isdir(site_dir):
            result['error'] = f"Directory {site_dir} does not exist"
            logging.error(result['error'])
            return result
            
        # Verify container exists
        if not container_exists(container_name):
            result['error'] = f"Container {container_name} not found or not running"
            logging.error(result['error'])
            return result
            
        # Verify wp-content directory exists
        if not os.path.isdir(wp_content_dir):
            result['error'] = f"wp-content directory {wp_content_dir} does not exist"
            logging.error(result['error'])
            return result
        
        # Step 1: Disconnect from malcare
        logging.info("Disconnecting from malcare...")
        try:
            run_wp_command(container_name, ['malcare', 'disconnect'])
        except subprocess.CalledProcessError as e:
            logging.warning(f"Malcare disconnect failed (may not be installed): {e}")
        
        # Step 2: Remove license-related WordPress options
        logging.info("Removing WordPress license options...")
        for option in OPTIONS_TO_REMOVE:
            try:
                run_wp_command(container_name, ['option', 'delete', option])
                logging.info(f"Removed option: {option}")
            except subprocess.CalledProcessError:
                logging.warning(f"Option {option} not found or could not be deleted")
        
        # Step 3: Update license status
        logging.info("Updating license status...")
        try:
            run_wp_command(container_name, ['option', 'update', '_transient_astra-addon_license_status', '0'])
        except subprocess.CalledProcessError as e:
            logging.warning(f"Could not update license status: {e}")
        
        # Step 4: Update admin email
        logging.info(f"Updating admin email to: {admin_email}")
        try:
            run_wp_command(container_name, ['option', 'update', 'admin_email', admin_email])
        except subprocess.CalledProcessError as e:
            logging.warning(f"Could not update admin email: {e}")
        
        # Step 5: Create new admin user
        random_password = generate_password()
        logging.info(f"Creating new admin user with email: {admin_email}")
        try:
            # Try to create user (may fail if exists)
            run_wp_command(container_name, [
                'user', 'create', admin_email, admin_email,
                '--role=administrator',
                '--display_name=New Admin', 
                '--user_nicename=New Admin',
                '--first_name=New',
                '--last_name=Admin',
                f'--user_pass={random_password}'
            ])
        except subprocess.CalledProcessError:
            # User might exist, try to update instead
            logging.info("User exists, updating instead...")
            try:
                run_wp_command(container_name, [
                    'user', 'update', admin_email,
                    '--role=administrator',
                    '--display_name=New Admin',
                    '--user_nicename=New Admin', 
                    '--first_name=New',
                    '--last_name=Admin',
                    f'--user_pass={random_password}'
                ])
            except subprocess.CalledProcessError as e:
                logging.warning(f"Could not create/update admin user: {e}")
        
        result['admin_password'] = random_password
        
        # Step 6: Export database
        logging.info("Exporting database...")
        try:
            run_wp_command(container_name, ['db', 'export', 'wp-content/mysql.sql'])
        except subprocess.CalledProcessError as e:
            logging.warning(f"Database export failed: {e}")
        
        # Step 7: Create zip archive
        logging.info(f"Creating zip archive: {zip_file}")
        zip_result = subprocess.run(['zip', '-rq', zip_file, site_dir], 
                                  capture_output=True, text=True)
        if zip_result.returncode != 0:
            result['error'] = f"Failed to create zip archive: {zip_result.stderr}"
            logging.error(result['error'])
            return result
        
        # Step 8: Change ownership and move zip file
        logging.info("Moving zip file to wp-content directory...")
        subprocess.run(['chown', 'www-data:www-data', zip_file], check=True)
        
        zip_destination = os.path.join(wp_content_dir, f"{full_domain}.zip")
        shutil.move(zip_file, zip_destination)
        
        # Success!
        result['success'] = True
        result['zip_url'] = f"https://{full_domain}/wp-content/{full_domain}.zip"
        
        logging.info(f"Cancellation completed successfully for {full_domain}")
        logging.info(f"Zip file URL: {result['zip_url']}")
        logging.info(f"New admin email: {admin_email}")
        logging.info(f"New admin password: {random_password}")
        
        return result
        
    except Exception as e:
        result['error'] = f"Unexpected error during cancellation: {str(e)}"
        logging.error(result['error'])
        return result

def main():
    """Main execution function."""
    parser = argparse.ArgumentParser(
        description="Process a Google Sheet to cancel WordPress hosting for listed websites.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
    )
    parser.add_argument('--creds-file', required=True, help="Path to Google service account JSON key.")
    parser.add_argument('--spreadsheet-id', required=True, help="Google Sheet ID to process.")
    parser.add_argument('--sheet-name', default=DEFAULT_SHEET_NAME, help="Name of the worksheet to read from.")
    parser.add_argument('--url-column', default=DEFAULT_URL_COLUMN, help="Header of the column containing website URLs.")
    parser.add_argument('--email-column', default=DEFAULT_EMAIL_COLUMN, help="Header of the column containing website emails.")
    parser.add_argument('--log-file', default=DEFAULT_LOG_FILE, help="Path to the log file for output.")
    parser.add_argument('--base-dir', default=DEFAULT_BASE_DIR, help="The base directory where site subdirectories are located.")
    parser.add_argument('--log-sheet', default=DEFAULT_LOG_SHEET_NAME, help="Name of the worksheet to log results.")
    parser.add_argument('--dry-run', action='store_true', help="Simulate execution without making changes.")
    
    args = parser.parse_args()
    setup_logging()

    if args.dry_run:
        logging.info("--- DRY RUN MODE ENABLED: No actual changes will be made. ---")

    # Check system dependencies
    if not args.dry_run and not check_dependencies():
        sys.exit(1)

    # Connect to Google Sheets
    spreadsheet = get_spreadsheet(args.spreadsheet_id, args.creds_file)
    if not spreadsheet:
        sys.exit(1)

    # Get source worksheet
    try:
        source_worksheet = spreadsheet.worksheet(args.sheet_name)
    except gspread.exceptions.WorksheetNotFound:
        logging.error(f"Error: Source worksheet '{args.sheet_name}' not found in the spreadsheet.")
        sys.exit(1)

    # Get or create log worksheet
    log_worksheet = None
    try:
        log_worksheet = spreadsheet.worksheet(args.log_sheet)
        logging.info(f"Using existing log sheet: '{args.log_sheet}'")
    except gspread.exceptions.WorksheetNotFound:
        if args.dry_run:
            logging.info(f"[DRY RUN] Would create new log sheet: '{args.log_sheet}'")
        else:
            logging.info(f"Log sheet '{args.log_sheet}' not found, creating it.")
            try:
                log_worksheet = spreadsheet.add_worksheet(title=args.log_sheet, rows=100, cols=4)
                log_worksheet.append_row(['URL', 'Date & Time', 'Link to zip file', 'Admin Email'], 
                                       value_input_option='USER_ENTERED')
            except Exception as e:
                logging.error(f"Could not create log sheet '{args.log_sheet}': {e}")
                sys.exit(1)

    # Prepare log file
    log_path = os.path.expanduser(args.log_file)
    if not args.dry_run:
        try:
            os.makedirs(os.path.dirname(log_path), exist_ok=True)
        except OSError as e:
            logging.error(f"Could not create log directory '{os.path.dirname(log_path)}': {e}")
            sys.exit(1)

    # Fetch and process data
    try:
        all_data = source_worksheet.get_all_values()
        if not all_data or len(all_data) < 4:
            logging.info("Spreadsheet has fewer than 4 rows. Nothing to process.")
            return

        header = all_data[2]  # Header is on the 3rd row
        logging.info(f"Header row (row 3): {header}")
        
        if args.url_column not in header:
            logging.error(f"Column '{args.url_column}' not found in sheet header (row 3): {header}")
            sys.exit(1)
        url_col_index = header.index(args.url_column)

        if args.email_column not in header:
            logging.error(f"Column '{args.email_column}' not found in sheet header (row 3): {header}")
            sys.exit(1)
        email_col_index = header.index(args.email_column)

    except Exception as e:
        logging.error(f"Failed to retrieve data from Google Sheet: {e}")
        sys.exit(1)

    # Process rows in reverse to avoid issues with row index shifting on deletion
    rows_to_process = all_data[3:]
    for i in range(len(rows_to_process) - 1, -1, -1):
        row_index_in_sheet = i + 4  # Start from row 4
        row = rows_to_process[i]
        
        if len(row) <= url_col_index or not row[url_col_index].strip():
            continue  # Skip empty rows

        url = row[url_col_index].strip()
        
        # Get admin email from the same row
        admin_email = DEFAULT_FALLBACK_ADMIN_EMAIL  # fallback
        if len(row) > email_col_index and row[email_col_index].strip():
            admin_email = row[email_col_index].strip()
        
        logging.info(f"Processing URL from row {row_index_in_sheet}: {url}")
        logging.info(f"Admin email for this site: {admin_email}")

        # Parse hostname from URL
        parsed_url = urlparse(url if url.startswith(('http://', 'https://')) else f'https://{url}')
        hostname = parsed_url.netloc
        if not hostname:
            logging.warning(f"Could not parse hostname from URL '{url}'. Skipping.")
            continue
        
        logging.info(f"Processing hostname: {hostname}")

        # Process the cancellation
        cancellation_result = cancel_wordpress_site(
            hostname, 
            args.base_dir, 
            admin_email,
            args.dry_run
        )
        
        timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        
        if cancellation_result['success']:
            # Log successful cancellation
            if log_worksheet and not args.dry_run:
                log_worksheet.append_row([
                    url,
                    timestamp, 
                    cancellation_result['zip_url'],
                    cancellation_result['admin_email']
                ], value_input_option='USER_ENTERED')
                logging.info(f"Logged successful cancellation for '{url}' to sheet '{args.log_sheet}'.")
            elif args.dry_run:
                logging.info(f"[DRY RUN] Would log successful cancellation for '{url}' to sheet '{args.log_sheet}'.")
            
            # Delete row from source sheet on success
            if not args.dry_run:
                logging.info(f"Deleting row {row_index_in_sheet} from Google Sheet.")
                source_worksheet.delete_rows(row_index_in_sheet)
            else:
                logging.info(f"[DRY RUN] Would delete row {row_index_in_sheet} from Google Sheet.")
        else:
            logging.error(f"Cancellation failed for '{hostname}': {cancellation_result['error']}")
            logging.error("The row will NOT be deleted from the sheet.")

    logging.info("Script finished.")

if __name__ == '__main__':
    main()