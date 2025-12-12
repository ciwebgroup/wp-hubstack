# Minimal Dockerfile to run wp-update-suite
FROM python:3.11-slim

# Install system deps for ruamel.yaml/pyyaml and docker client
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libyaml-dev \
    ca-certificates \
    curl \
    docker.io \
    git \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy project files
COPY . /app

# Make run.sh executable
RUN chmod +x /app/run.sh

ENTRYPOINT ["python3", "main.py"]
