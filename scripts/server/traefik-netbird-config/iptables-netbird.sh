#!/bin/bash
# NetBird VPN Lockdown for Traefik port 8082
# Restricts access to ONLY the NetBird VPN interface (wt0)
set -eauo pipefail

echo "=== Cleaning up existing 8082 rules ==="
# Remove any existing rules (ignore errors if they don't exist)
iptables -D DOCKER-USER -p tcp --dport 8082 -j DROP 2>/dev/null || true
iptables -D DOCKER-USER -p tcp --dport 8082 -s 127.0.0.1 -j DROP 2>/dev/null || true
iptables -D DOCKER-USER -p tcp --dport 8082 -i wt0 -j ACCEPT 2>/dev/null || true
iptables -D INPUT -p tcp --dport 8082 -j DROP 2>/dev/null || true
iptables -D INPUT -p tcp --dport 8082 -s 127.0.0.1 -j DROP 2>/dev/null || true
iptables -D INPUT -p tcp --dport 8082 -i wt0 -j ACCEPT 2>/dev/null || true

echo "=== Adding DOCKER-USER chain rules (primary protection) ==="
iptables -I DOCKER-USER 1 -p tcp --dport 8082 -i wt0 -j ACCEPT
iptables -I DOCKER-USER 2 -p tcp --dport 8082 -s 127.0.0.1 -j DROP
iptables -I DOCKER-USER 3 -p tcp --dport 8082 -j DROP

echo "=== Adding INPUT chain rules (backup defense) ==="
iptables -I INPUT 2 -p tcp --dport 8082 -i wt0 -j ACCEPT
iptables -I INPUT 3 -p tcp --dport 8082 -s 127.0.0.1 -j DROP
iptables -I INPUT 4 -p tcp --dport 8082 -j DROP

echo "=== Persisting rules ==="
netfilter-persistent save

echo "=== Done! Verifying rules ==="
echo "DOCKER-USER chain:"
iptables -L DOCKER-USER -n -v --line-numbers | grep 8082 || echo "  (no rules found)"
echo ""
echo "INPUT chain:"
iptables -L INPUT -n -v --line-numbers | grep 8082 || echo "  (no rules found)"