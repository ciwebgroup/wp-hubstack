# Install Python 3.12

if ! command -v python3.12 &> /dev/null; then
	apt update
	apt install -y python3.12
	if [ $? -ne 0 ]; then
		echo "Failed to install python3.12. Please check your package manager."
		exit 1
	fi
else
	echo "python3.12 is already installed."
fi

# Install python3.12-venv
if ! python3.12 -m venv --help &> /dev/null; then
	apt install -y python3.12-venv
	if [ $? -ne 0 ]; then
		echo "Failed to install python3.12-venv. Please check your package manager."
		exit 1
	fi
else	
	echo "python3.12-venv is already installed."
fi

rm -rf .venv

python3.12 ./venv_utils.py create -n .venv
python3.12 ./venv_utils.py activate .venv
. .venv/bin/activate
python3.12 ./venv_utils install -r requirements.txt

# python3.12 ./src/main.py "$@"
python3.12 ./src/main.py --container-name "wp_bannerair" --output-csv-path "/var/opt/bannerair.com/"