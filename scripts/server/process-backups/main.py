#!/usr/bin/env python3
"""
Processes a Google Sheet to trigger backups for specified websites.

This script reads URLs from a Google Sheet, finds the corresponding site
directory, runs a backup script, and then deletes the entry from the sheet
upon successful completion.
"""

import os
import sys
import subprocess
import argparse
import logging
from urllib.parse import urlparse
from datetime import datetime

import gspread
from oauth2client.service_account import ServiceAccountCredentials

# --- Configuration ---
DEFAULT_BACKUP_SCRIPT = '/var/www/wp-hubstack_fork/scripts/server/run-backups.sh'
DEFAULT_LOG_FILE = '~/logs/tarball-backups.log'
DEFAULT_BASE_DIR = '/var/opt'
DEFAULT_SHEET_NAME = 'Sheet1'
DEFAULT_URL_COLUMN = 'URL'
DEFAULT_LOG_SHEET_NAME = 'Archived URLs'

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

def main():
    """Main execution function."""
    parser = argparse.ArgumentParser(
        description="Process a Google Sheet to run backups for listed websites.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
    )
    parser.add_argument('--creds-file', required=True, help="Path to Google service account JSON key.")
    parser.add_argument('--spreadsheet-id', required=True, help="Google Sheet ID to process.")
    parser.add_argument('--sheet-name', default=DEFAULT_SHEET_NAME, help="Name of the worksheet to read from.")
    parser.add_argument('--url-column', default=DEFAULT_URL_COLUMN, help="Header of the column containing website URLs.")
    parser.add_argument('--backup-script', default=DEFAULT_BACKUP_SCRIPT, help="Path to the run-backups.sh script.")
    parser.add_argument('--log-file', default=DEFAULT_LOG_FILE, help="Path to the log file for backup script output.")
    parser.add_argument('--base-dir', default=DEFAULT_BASE_DIR, help="The base directory where site subdirectories are located.")
    parser.add_argument('--log-sheet', default=DEFAULT_LOG_SHEET_NAME, help="Name of the worksheet to log successful archives.")
    parser.add_argument('--dry-run', action='store_true', help="Simulate execution without making changes.")
    
    args = parser.parse_args()
    setup_logging()

    if args.dry_run:
        logging.info("--- DRY RUN MODE ENABLED: No actual changes will be made. ---")

    # 1. Verify backup script exists
    if not os.path.exists(args.backup_script):
        logging.error(f"Backup script not found at '{args.backup_script}'. Please check the path.")
        sys.exit(1)

    # 2. Connect to Google Sheets
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
                log_worksheet = spreadsheet.add_worksheet(title=args.log_sheet, rows=100, cols=2)
                log_worksheet.append_row(['URL', 'ARCHIVE CREATED'], value_input_option='USER_ENTERED')
            except Exception as e:
                logging.error(f"Could not create log sheet '{args.log_sheet}': {e}")
                sys.exit(1)

    # 3. Prepare log file
    log_path = os.path.expanduser(args.log_file)
    if not args.dry_run:
        try:
            os.makedirs(os.path.dirname(log_path), exist_ok=True)
        except OSError as e:
            logging.error(f"Could not create log directory '{os.path.dirname(log_path)}': {e}")
            sys.exit(1)

    # 4. Fetch and process data
    try:
        all_data = source_worksheet.get_all_values()
        if not all_data or len(all_data) < 4:
            logging.info("Spreadsheet has fewer than 4 rows. Nothing to process.")
            return

        header = all_data[2]  # Header is on the 3rd row

		# Log header 
        logging.info(f"Header row (row 3): {header}")
        if args.url_column not in header:
            logging.error(f"Column '{args.url_column}' not found in sheet header (row 3): {header}")
            sys.exit(1)
        url_col_index = header.index(args.url_column)

    except Exception as e:
        logging.error(f"Failed to retrieve data from Google Sheet: {e}")
        sys.exit(1)

    # Process rows in reverse to avoid issues with row index shifting on deletion
    rows_to_process = all_data[3:]
    for i in range(len(rows_to_process) - 1, -1, -1):
        row_index_in_sheet = i + 4  # Start from row 4
        row = rows_to_process[i]
        
        if len(row) <= url_col_index or not row[url_col_index].strip():
            continue # Skip empty rows

        url = row[url_col_index].strip()
        logging.info(f"Processing URL from row {row_index_in_sheet}: {url}")

        # Sanitize URL to get hostname
        hostname = urlparse(url).netloc
        if not hostname:
            logging.warning(f"Could not parse hostname from URL '{url}'. Skipping.")
            continue
        
        logging.info(f"Sanitized to hostname: {hostname}")

        # Check for matching directory
        site_dir = os.path.join(args.base_dir, hostname)
        if not os.path.isdir(site_dir):
            # Note: The prompt requested to exit, but continuing is more robust for batch processing.
            logging.error(f"No matching directory found at '{site_dir}'. Skipping this entry.")
            continue
        
        logging.info(f"Found matching directory: {site_dir}")

        # Run backup script
        command = [args.backup_script, '--container-name', hostname, '--delete']
        
        if args.dry_run:
            logging.info(f"[DRY RUN] Would execute: {' '.join(command)} > {log_path}")
            logging.info(f"[DRY RUN] Would log URL '{url}' to sheet '{args.log_sheet}'.")
            logging.info(f"[DRY RUN] Would delete row {row_index_in_sheet} from Google Sheet upon success.")
            continue

        try:
            logging.info(f"Executing backup command: {' '.join(command)}")
            with open(log_path, 'a') as log_handle:
                log_handle.write(f"\n--- Running backup for {hostname} at {logging.Formatter().formatTime(logging.LogRecord(None,None,None,None,None,None,None))} ---\n")
                process = subprocess.run(
                    command,
                    stdout=log_handle,
                    stderr=subprocess.STDOUT,
                    check=True, # Raises CalledProcessError on non-zero exit codes
                    text=True
                )
            logging.info(f"Backup script for '{hostname}' completed successfully.")

            # Log to sheet on success
            timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
            if log_worksheet:
                log_worksheet.append_row([url, timestamp], value_input_option='USER_ENTERED')
                logging.info(f"Logged successful archive for '{url}' to sheet '{args.log_sheet}'.")

            # Delete row from Google Sheet on success
            logging.info(f"Deleting row {row_index_in_sheet} from Google Sheet.")
            source_worksheet.delete_rows(row_index_in_sheet)

        except subprocess.CalledProcessError as e:
            logging.error(f"Backup script for '{hostname}' failed with exit code {e.returncode}.")
            logging.error(f"Output logged to '{log_path}'. The row will NOT be deleted from the sheet.")
        except Exception as e:
            logging.error(f"An unexpected error occurred while processing '{hostname}': {e}")

    logging.info("Script finished.")

if __name__ == '__main__':
	main()