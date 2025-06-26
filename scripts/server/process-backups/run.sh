#!/bin/bash

rm -rf ./venv

rm -rf ./__pycache__

# Install python3.12-venv
if ! command -v python3.12 &> /dev/null; then
	apt install -y python3.12
	if [ $? -ne 0 ]; then
		echo "Failed to install python3.12. Please check your package manager."
		exit 1
	fi
fi

if ! python3.12 -m venv --help &> /dev/null; then
	apt install -y python3.12-venv
	if [ $? -ne 0 ]; then
		echo "Failed to install python3.12-venv. Please check your package manager."
		exit 1
	fi
fi

# Create a virtual environment
if [ ! -d "venv" ]; then
	venv_utils create -n venv
	if [ $? -ne 0 ]; then
		echo "Failed to create virtual environment. Please check your Python installation."
		exit 1
	fi
else
	echo "Virtual environment already exists."
fi

venv_utils activate venv
if [ $? -ne 0 ]; then
	echo "Failed to activate virtual environment. Please check your Python installation."
	exit 1
fi

# Activate the virtual environment
source venv/bin/activate

# Install required packages
venv_utils install -r requirements.txt
if [ $? -ne 0 ]; then
	echo "Failed to install required packages. Please check your requirements.txt file."
	exit 1
fi

# Run the main script with provided arguments
python3.12 main.py --creds-file ./site-url-python-script-6a43db57673f.json \
	--spreadsheet-id "1swBOVDOm97UTnQzJI_DqzbNbjwBI0FkVFGVkRFnu-2Y" \
	--sheet-name "Archive" \
	--log-sheet "Log" \
	--backup-script /var/opt/scripts/run-backups.sh