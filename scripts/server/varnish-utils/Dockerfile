FROM python:3.11-slim

# Install minimal tools and Docker CLI so the container can control host Docker
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    wget \
    gnupg2 \
    apt-transport-https \
    docker.io \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /workdir
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

COPY . /workdir
RUN chmod +x /workdir/varnish_utils.py

# Run in interactive mode by default; use `docker-compose run --rm varnish-utils test ...`
ENTRYPOINT ["/workdir/varnish_utils.py"]
CMD ["--help"]
