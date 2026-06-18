#!/usr/bin/env bash
# Phase 4 — generate the Reality x25519 keypair + shortId and inject them (plus
# your validated camouflage SNI) into xray/xray_config.json. Private material is
# saved to secrets/reality.txt (0600). The PUBLIC key + shortId + SNI are what
# you enter into the Marzban "Host" for this inbound and/or share with clients.
#
# Usage:  REALITY_SNI=www.example.com ./scripts/02-gen-reality-keys.sh
#   (or set REALITY_SNI in your environment / pass it interactively)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$ROOT/xray/xray_config.json"
SECRET="$ROOT/secrets/reality.txt"
BIN="$ROOT/xray/bin/xray"
IMAGE="${MARZBAN_IMAGE:-gozargah/marzban:latest}"

: "${REALITY_SNI:?Set REALITY_SNI to a validated TLS1.3 camouflage domain (run scripts/validate-sni.sh first)}"

# Prefer the locally fetched core (same version that will actually run); fall
# back to the Marzban image if the binary isn't present yet.
if [[ -x "$BIN" ]]; then
  echo "==> Generating x25519 keypair (via local $BIN)"
  KP="$("$BIN" x25519)"
else
  docker_cmd="docker"; docker info >/dev/null 2>&1 || docker_cmd="sudo docker"
  echo "==> Generating x25519 keypair (via $IMAGE)"
  KP="$($docker_cmd run --rm --entrypoint xray "$IMAGE" x25519)"
fi
# Handle both old (Private key:/Public key:) and new (PrivateKey:/Password (PublicKey):) labels.
PRIV="$(echo "$KP" | awk -F': *' '/[Pp]rivate/{print $2}')"
PUB="$(echo  "$KP" | awk -F': *' '/[Pp]ublic/{print $2}')"
SID="$(openssl rand -hex 8)"

[[ -n "$PRIV" && -n "$PUB" ]] || { echo "Key generation failed; raw output:"; echo "$KP"; exit 1; }

echo "==> Writing private material to $SECRET (0600)"
umask 077
cat > "$SECRET" <<EOF
# FINFA Reality secrets — generated $(date -u +%FT%TZ). KEEP PRIVATE.
REALITY_SNI=$REALITY_SNI
REALITY_PRIVATE_KEY=$PRIV
REALITY_PUBLIC_KEY=$PUB
REALITY_SHORT_ID=$SID
EOF
chmod 600 "$SECRET"

# Random, per-deploy path for the (optional) Cloudflare CDN (XHTTP) inbound,
# so the path isn't a constant fingerprint across FINFA installs. Harmless if CDN is unused.
CDNPATH="${CDNPATH:-/$(openssl rand -hex 8)}"

echo "==> Injecting SNI / privateKey / shortId / cdn-path into $CFG"
# Replace placeholders (works on a fresh config; re-run regenerates from secrets if needed).
sed -i \
  -e "s#__REALITY_SNI__#${REALITY_SNI}#g" \
  -e "s#__REALITY_PRIVATE_KEY__#${PRIV}#g" \
  -e "s#__REALITY_SHORT_ID__#${SID}#g" \
  -e "s#__CDN_PATH__#${CDNPATH}#g" \
  "$CFG"

echo
echo "================ CLIENT / MARZBAN HOST VALUES (not secret) ================"
echo "  SNI / serverName : $REALITY_SNI"
echo "  Public key (pbk) : $PUB"
echo "  shortId (sid)    : $SID"
echo "  flow             : xtls-rprx-vision"
echo "  fingerprint (fp) : chrome"
echo "=========================================================================="
echo "Private key is in $SECRET only. Now (re)start: ./scripts/04-up.sh"
