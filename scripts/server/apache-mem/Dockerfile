FROM python:3.11-slim

# Install system dependencies
# docker-cli is needed to run 'docker compose' commands via subprocess
RUN apt-get update && apt-get install -y \
	docker.io \
	&& rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY tuner.py .

# Entrypoint
ENTRYPOINT ["python", "tuner.py"]

# Default command (can be overridden)
CMD ["--help"]