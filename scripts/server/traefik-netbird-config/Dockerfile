FROM python:3.12-slim

LABEL maintainer="CIWebGroup"
LABEL description="Traefik Config Manager - Type-safe CLI for managing Traefik configurations"

WORKDIR /app

# Install Docker CLI for container management (--restart flag needs this)
# Install iptables and netfilter-persistent for firewall rule management
RUN apt-get update && apt-get install -y --no-install-recommends \
	ca-certificates \
	curl \
	iptables \
	netfilter-persistent \
	&& install -m 0755 -d /etc/apt/keyrings \
	&& curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
	&& chmod a+r /etc/apt/keyrings/docker.asc \
	&& echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list \
	&& apt-get update \
	&& apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
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

