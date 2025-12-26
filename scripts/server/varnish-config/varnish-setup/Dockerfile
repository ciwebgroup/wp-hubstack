FROM python:3.11-alpine

LABEL maintainer="CIWG"
LABEL description="Varnish Setup Script for Traefik + WordPress"

# Install Docker CLI for container management
RUN apk add --no-cache \
	docker-cli \
	curl \
	bash

WORKDIR /app

# Copy setup files
COPY setup.py /app/
COPY templates/ /app/templates/

# Make setup script executable
RUN chmod +x /app/setup.py

# Default command
CMD ["python3", "/app/setup.py"]
