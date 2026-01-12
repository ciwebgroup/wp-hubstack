FROM python:3.11-slim

# Install minimal system deps
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Python deps
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

# Copy script
COPY fix_oidc_settings.py /app/fix_oidc_settings.py
RUN chmod +x /app/fix_oidc_settings.py

ENTRYPOINT ["/usr/local/bin/python", "/app/fix_oidc_settings.py"]
