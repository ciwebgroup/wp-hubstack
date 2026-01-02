FROM python:3.12-slim

LABEL maintainer="CIWebGroup"
LABEL description="Traefik Config Manager - Type-safe CLI for managing Traefik configurations"

WORKDIR /app

# Install Docker CLI for container management
RUN apt-get update && apt-get install -y --no-install-recommends \
	docker.io \
	&& rm -rf /var/lib/apt/lists/*

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Install dev dependencies for type checking
RUN pip install --no-cache-dir mypy pytest pytest-cov ruff

# Copy source code
COPY src/ ./src/
COPY pyproject.toml .

# Install the package in editable mode
RUN pip install -e .

ENTRYPOINT ["traefik-config"]
CMD ["--help"]
