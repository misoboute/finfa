#!/usr/bin/env bash
# Download the latest Xray-core release binary into xray/bin/xray.
#
# Why this exists: the stock Marzban image bundles an older Xray core that can't
# parse the post-quantum TLS key share modern clients send, so every updated
# client fails Reality auth. We run a current core via a bind-mount instead of
# rebuilding the image. Re-run this any time to upgrade, then `compose up -d`.
#
# Usage:  ./scripts/fetch-xray.sh [version]   (default: latest)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/xray/bin/xray"
VER="${1:-latest}"

case "$(uname -m)" in
  x86_64|amd64) ASSET="Xray-linux-64.zip" ;;
  aarch64|arm64) ASSET="Xray-linux-arm64-v8a.zip" ;;
  *) echo "Unsupported arch $(uname -m); edit fetch-xray.sh." >&2; exit 1 ;;
esac

if [[ "$VER" == latest ]]; then
  VER="$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest \
         | grep -m1 '"tag_name"' | cut -d'"' -f4)"
  [[ -n "$VER" ]] || { echo "Could not resolve latest version (GitHub rate limit?). Pass one explicitly." >&2; exit 1; }
fi

URL="https://github.com/XTLS/Xray-core/releases/download/${VER}/${ASSET}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "==> Downloading Xray $VER ($ASSET)"
curl -fSL --retry 3 -o "$TMP/x.zip" "$URL"
( cd "$TMP" && unzip -oq x.zip xray )
install -m 0755 "$TMP/xray" "$DEST"
echo "==> Installed $("$DEST" version 2>/dev/null | head -1) -> $DEST"
