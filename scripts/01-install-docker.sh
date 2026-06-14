#!/usr/bin/env bash
# Phase 1 — install Docker Engine + compose plugin from Docker's official apt repo.
# VERIFY this matches the current official instructions at
# https://docs.docker.com/engine/install/ubuntu/ before running.
#
# Does NOT add any user to the docker group (per the handoff). Use sudo for docker.
set -euo pipefail
if [[ $EUID -ne 0 ]]; then echo "Run with sudo." >&2; exit 1; fi

echo "==> Prereqs"
apt-get update -qq
apt-get install -y ca-certificates curl gnupg

echo "==> Docker GPG key"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "==> Docker apt repo"
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

echo "==> Install engine + compose plugin"
apt-get update -qq
apt-get install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker
echo "==> Versions"
docker version | head -8
docker compose version
echo "Done. Use 'sudo docker ...' (no user added to the docker group)."
