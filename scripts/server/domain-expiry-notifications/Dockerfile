# Dockerfile for domain expiry notifications
FROM python:3.11-slim

# Install system dependencies including whois utility
RUN apt-get update && apt-get install -y --no-install-recommends \
	whois \
	ca-certificates \
	docker.io \
	&& rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy requirements and install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy project files
COPY . /app

# Make the main script executable
RUN chmod +x /app/main.py

ENTRYPOINT ["python3", "main.py"]
