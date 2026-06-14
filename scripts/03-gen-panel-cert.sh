#!/usr/bin/env bash
# Generate a private CA and a CA-signed server cert for the Marzban panel.
#
# Why: Marzban rejects self-signed certs and only binds Uvicorn to 0.0.0.0
# (required for Docker port-publish) when it can verify the cert against a
# trusted CA. We create a private CA, install it into the container's trust
# store (via marzban.Dockerfile), and issue the panel cert from it.
#
# The CA and certs are localhost-only (SAN: 127.0.0.1 / localhost).
# They are never exposed publicly — only seen inside an SSH tunnel.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/secrets/panel-tls"
mkdir -p "$DIR"
chmod 700 "$DIR"

echo "==> Generating private CA"
openssl genrsa -out "$DIR/ca.key" 4096 2>/dev/null
openssl req -x509 -new -nodes -key "$DIR/ca.key" -sha256 -days 3650 \
  -subj "/CN=FINFA-Panel-CA" \
  -out "$DIR/ca.crt"

echo "==> Generating panel server key + CSR"
openssl genrsa -out "$DIR/panel.key" 4096 2>/dev/null
openssl req -new -key "$DIR/panel.key" \
  -subj "/CN=marzban-panel-local" \
  -out "$DIR/panel.csr"

echo "==> Signing with CA (SAN: 127.0.0.1 + localhost)"
openssl x509 -req -in "$DIR/panel.csr" \
  -CA "$DIR/ca.crt" -CAkey "$DIR/ca.key" -CAcreateserial \
  -days 3650 -sha256 \
  -extfile <(printf 'subjectAltName=IP:127.0.0.1,DNS:localhost') \
  -out "$DIR/panel.crt"

rm -f "$DIR/panel.csr"
chmod 600 "$DIR"/*
echo "Done. Files in $DIR (all 0600):"
ls -la "$DIR"
