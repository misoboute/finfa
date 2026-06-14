#!/usr/bin/env bash
# Build + bring up Marzban (panel on 127.0.0.1, Reality on :443). The watcher
# stays OFF by default (enable with --profile watcher). Run AFTER: docker
# installed, .env written, panel cert generated, Reality keys injected, and the
# Xray core fetched.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"

DC="docker compose"; docker info >/dev/null 2>&1 || DC="sudo docker compose"

[[ -f .env ]] || { echo ".env missing — run ./setup.sh (or copy .env.example)."; exit 1; }
[[ -x xray/bin/xray ]] || { echo "xray core missing — run ./scripts/fetch-xray.sh"; exit 1; }
grep -q '__REALITY_' xray/xray_config.json && {
  echo "xray_config.json still has placeholders — run scripts/02-gen-reality-keys.sh first."; exit 1; }

echo "==> Building image (installs the panel CA) + starting Marzban"
$DC build marzban
$DC up -d marzban

PORT="$(grep -E '^PANEL_PORT=' .env | cut -d= -f2)"
echo "==> Waiting for panel on 127.0.0.1:${PORT} ..."
python3 scripts/marzban.py wait || true

SERVER_IP="${SERVER_IP:-$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo YOUR_SERVER_IP)}"
echo
echo "Panel is up (loopback only). Reach it from your laptop via an SSH tunnel:"
echo "    ssh -L ${PORT}:127.0.0.1:${PORT} <user>@${SERVER_IP}"
echo "  then open  https://127.0.0.1:${PORT}/dashboard   (accept the private-CA warning)"
echo
echo "Confirm it is NOT public:  curl -m5 http://${SERVER_IP}:${PORT}/   (must fail/refuse)"
