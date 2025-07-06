#!/usr/bin/env python3
"""
Elementor Export to Google Drive Script

This script:
1. Discovers WordPress containers starting with '_wp'
2. Exports Elementor kits from each container
3. Uploads the exported files to Google Drive in organized directories

Usage:
    python elementor-export-to-drive.py --auth-json /path/to/credentials.json --drive-folder-id FOLDER_ID

Requirements:
    - google-api-python-client
    - google-auth-httplib2
    - google-auth-oauthlib
    - docker
"""

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import List, Dict, Optional

try:
    from googleapiclient.discovery import build
    from googleapiclient.http import MediaFileUpload
    from google.oauth2.service_account import Credentials
    from google.auth.transport.requests import Request
except ImportError as e:
    print(f"Error: Missing required Google API libraries. Install with:")
    print("pip install google-api-python-client google-auth-httplib2 google-auth-oauthlib")
    sys.exit(1)


class ElementorExporter:
    def __init__(self, auth_json_path: str, drive_folder_id: str):
        """Initialize the Elementor Exporter with Google Drive credentials."""
        self.auth_json_path = auth_json_path
        self.drive_folder_id = drive_folder_id
        self.drive_service = None
        self._authenticate()

    def _authenticate(self):
        """Authenticate with Google Drive API using service account credentials."""
        try:
            if not os.path.exists(self.auth_json_path):
                raise FileNotFoundError(f"Auth JSON file not found: {self.auth_json_path}")
            
            # Define the scopes for Google Drive API
            scopes = ['https://www.googleapis.com/auth/drive']
            
            # Load credentials from the JSON file
            credentials = Credentials.from_service_account_file(
                self.auth_json_path, scopes=scopes
            )
            
            # Build the Drive service
            self.drive_service = build('drive', 'v3', credentials=credentials)
            print("Successfully authenticated with Google Drive API")
            
        except Exception as e:
            print(f"Error authenticating with Google Drive: {e}")
            sys.exit(1)

    def get_wp_containers(self) -> List[Dict[str, str]]:
        """Get all Docker containers with names starting with '_wp'."""
        try:
            # Run docker ps to get container information
            result = subprocess.run(
                ['docker', 'ps', '--format', '{{.Names}}'],
                capture_output=True,
                text=True,
                check=True
            )
            
            # Filter containers starting with '_wp'
            containers = []
            for line in result.stdout.strip().split('\n'):
                if line.startswith('_wp'):
                    containers.append({
                        'name': line,
                        'working_dir': self._get_container_working_dir(line)
                    })
            
            print(f"Found {len(containers)} WordPress containers")
            return containers
            
        except subprocess.CalledProcessError as e:
            print(f"Error running docker ps: {e}")
            return []
        except Exception as e:
            print(f"Error getting WordPress containers: {e}")
            return []

    def _get_container_working_dir(self, container_name: str) -> Optional[str]:
        """Get the working directory of a container using docker inspect."""
        try:
            result = subprocess.run([
                'docker', 'inspect', container_name
            ], capture_output=True, text=True, check=True)
            
            # Parse the JSON output
            inspect_data = json.loads(result.stdout)
            if inspect_data and len(inspect_data) > 0:
                labels = inspect_data[0].get('Config', {}).get('Labels', {})
                working_dir = labels.get('com.docker.compose.project.working_dir')
                return working_dir
            
        except (subprocess.CalledProcessError, json.JSONDecodeError, KeyError) as e:
            print(f"Error getting working directory for {container_name}: {e}")
        
        return None

    def export_elementor_kit(self, container_name: str) -> Optional[str]:
        """Export Elementor kit from a WordPress container."""
        try:
            # Extract URL from container name (remove '_wp' prefix and any suffixes)
            url = container_name.replace('_wp', '').split('_')[0]
            
            # Generate timestamp
            timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
            
            # Create export filename
            export_filename = f"{url}-elementor-export-{timestamp}.zip"
            
            print(f"Exporting Elementor kit from {container_name}...")
            
            # Run the wp command to export Elementor kit
            wp_command = [
                'docker', 'exec', '-u', '0', container_name,
                'wp', '--allow-root', 'plugin', 'elementor', 'kit', 'export',
                export_filename
            ]
            
            result = subprocess.run(wp_command, capture_output=True, text=True, check=True)
            print(f"Export command output: {result.stdout}")
            
            # Move the file to wp-content directory
            move_command = [
                'docker', 'exec', '-u', '0', container_name,
                'mv', export_filename, 'wp-content/'
            ]
            
            subprocess.run(move_command, capture_output=True, text=True, check=True)
            print(f"Moved {export_filename} to wp-content directory")
            
            return f"wp-content/{export_filename}"
            
        except subprocess.CalledProcessError as e:
            print(f"Error exporting Elementor kit from {container_name}: {e}")
            if e.stderr:
                print(f"Error output: {e.stderr}")
            return None
        except Exception as e:
            print(f"Unexpected error exporting from {container_name}: {e}")
            return None

    def create_drive_folder(self, folder_name: str, parent_folder_id: str) -> Optional[str]:
        """Create a folder in Google Drive."""
        try:
            # Check if folder already exists
            query = f"name='{folder_name}' and parents='{parent_folder_id}' and mimeType='application/vnd.google-apps.folder'"
            results = self.drive_service.files().list(q=query).execute()
            items = results.get('files', [])
            
            if items:
                print(f"Folder '{folder_name}' already exists")
                return items[0]['id']
            
            # Create new folder
            file_metadata = {
                'name': folder_name,
                'parents': [parent_folder_id],
                'mimeType': 'application/vnd.google-apps.folder'
            }
            
            folder = self.drive_service.files().create(body=file_metadata, fields='id').execute()
            folder_id = folder.get('id')
            print(f"Created folder '{folder_name}' with ID: {folder_id}")
            return folder_id
            
        except Exception as e:
            print(f"Error creating folder '{folder_name}': {e}")
            return None

    def upload_file_to_drive(self, local_file_path: str, drive_folder_id: str, filename: str) -> bool:
        """Upload a file to Google Drive."""
        try:
            file_metadata = {
                'name': filename,
                'parents': [drive_folder_id]
            }
            
            media = MediaFileUpload(local_file_path, resumable=True)
            
            file = self.drive_service.files().create(
                body=file_metadata,
                media_body=media,
                fields='id'
            ).execute()
            
            print(f"Successfully uploaded {filename} to Google Drive (ID: {file.get('id')})")
            return True
            
        except Exception as e:
            print(f"Error uploading {filename} to Google Drive: {e}")
            return False

    def copy_file_from_container(self, container_name: str, container_path: str, local_path: str) -> bool:
        """Copy a file from Docker container to local filesystem."""
        try:
            command = ['docker', 'cp', f"{container_name}:{container_path}", local_path]
            subprocess.run(command, check=True)
            print(f"Copied {container_path} from {container_name} to {local_path}")
            return True
        except subprocess.CalledProcessError as e:
            print(f"Error copying file from container: {e}")
            return False

    def process_container(self, container_info: Dict[str, str]) -> bool:
        """Process a single container: export kit and upload to Drive."""
        container_name = container_info['name']
        print(f"\n--- Processing container: {container_name} ---")
        
        # Export Elementor kit
        export_path = self.export_elementor_kit(container_name)
        if not export_path:
            print(f"Failed to export Elementor kit from {container_name}")
            return False
        
        # Create folder in Google Drive
        folder_id = self.create_drive_folder(container_name, self.drive_folder_id)
        if not folder_id:
            print(f"Failed to create Drive folder for {container_name}")
            return False
        
        # Copy file from container to local temp directory
        temp_dir = Path('/tmp/elementor_exports')
        temp_dir.mkdir(exist_ok=True)
        
        local_file_path = temp_dir / Path(export_path).name
        
        if not self.copy_file_from_container(container_name, export_path, str(local_file_path)):
            return False
        
        # Upload to Google Drive
        success = self.upload_file_to_drive(str(local_file_path), folder_id, Path(export_path).name)
        
        # Clean up local temp file
        try:
            local_file_path.unlink()
            print(f"Cleaned up temporary file: {local_file_path}")
        except Exception as e:
            print(f"Warning: Could not remove temp file {local_file_path}: {e}")
        
        return success

    def run(self):
        """Main execution method."""
        print("Starting Elementor Export to Google Drive process...")
        
        # Get all WordPress containers
        containers = self.get_wp_containers()
        if not containers:
            print("No WordPress containers found")
            return
        
        # Process each container
        successful_exports = 0
        for container_info in containers:
            if self.process_container(container_info):
                successful_exports += 1
        
        print(f"\n--- Summary ---")
        print(f"Total containers processed: {len(containers)}")
        print(f"Successful exports: {successful_exports}")
        print(f"Failed exports: {len(containers) - successful_exports}")


def main():
    """Main function to parse arguments and run the exporter."""
    parser = argparse.ArgumentParser(
        description="Export Elementor kits from WordPress containers to Google Drive"
    )
    
    parser.add_argument(
        '--auth-json',
        required=True,
        help='Path to Google Service Account JSON credentials file'
    )
    
    parser.add_argument(
        '--drive-folder-id',
        required=True,
        help='Google Drive folder ID where exports will be stored'
    )
    
    args = parser.parse_args()
    
    # Initialize and run the exporter
    exporter = ElementorExporter(args.auth_json, args.drive_folder_id)
    exporter.run()


if __name__ == '__main__':
    main() 