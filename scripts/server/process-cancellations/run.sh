#!/bin/bash

CANCELLATION_DIR="/var/opt/scripts/process-cancellations"

rm -rf $CANCELLATION_DIR/venv

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
if [ ! -d "$CANCELLATION_DIR/venv" ]; then
	venv_utils create -n $CANCELLATION_DIR/venv
	if [ $? -ne 0 ]; then
		echo "Failed to create virtual environment. Please check your Python installation."
		exit 1
	fi
else
	echo "Virtual environment already exists."
fi

venv_utils activate $CANCELLATION_DIR/venv
if [ $? -ne 0 ]; then
	echo "Failed to activate virtual environment. Please check your Python installation."
	exit 1
fi

# Activate the virtual environment
source $CANCELLATION_DIR/venv/bin/activate

# Install required packages
venv_utils install -r $CANCELLATION_DIR/requirements.txt
if [ $? -ne 0 ]; then
	echo "Failed to install required packages. Please check your requirements.txt file."
	exit 1
fi

# Run the main script with provided arguments for cancellation processing
python3.12 $CANCELLATION_DIR/main.py \
	--creds-file $CANCELLATION_DIR/site-url-python-script-6a43db57673f.json \
	--spreadsheet-id "1H-CeEZaoCpNg45HaBSqhUZPd-lJ1PgYyQXiBmVFEVz8" \
	--sheet-name "Sites To Be Canceled" \
	--log-sheet "Log" \
	--url-column "URL" \
	--email-column "Email" \
	--base-dir "/var/opt" \
	--log-file "~/logs/cancellation-processing.log" \
	"$@"
