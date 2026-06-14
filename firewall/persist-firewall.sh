#!/usr/bin/env bash
# Make the currently-applied FINFA ruleset survive reboot. Run this ONLY after
# you have applied it (apply-firewall.sh) and confirmed a fresh SSH session works.
#
# Strategy: install the rendered table (real SSH port baked in) into
# /etc/nftables.d/ and make /etc/nftables.conf include that drop-in. We do NOT
# 'flush ruleset' at boot so we don't stomp Docker's runtime-managed tables.
set -euo pipefail
if [[ $EUID -ne 0 ]]; then echo "Run with sudo." >&2; exit 1; fi

HERE="$(cd "$(dirname "$0")" && pwd)"
RULESET="$HERE/nftables-finfa.rendered.nft"
TARGET="/etc/nftables.d/finfa.nft"

[[ -f "$RULESET" ]] || { echo "Run apply-firewall.sh first (no rendered ruleset found)."; exit 1; }

echo "==> Installing $RULESET -> $TARGET"
mkdir -p /etc/nftables.d
install -m 0644 "$RULESET" "$TARGET"

# Ensure /etc/nftables.conf includes our drop-in (don't duplicate the include).
if ! grep -q 'include "/etc/nftables.d/\*.nft"' /etc/nftables.conf 2>/dev/null; then
  echo '==> Adding include line to /etc/nftables.conf'
  printf '\ninclude "/etc/nftables.d/*.nft"\n' >> /etc/nftables.conf
fi

echo "==> Enabling nftables.service"
systemctl enable nftables.service
echo "Done. The FINFA table will load at boot. Docker tables are unaffected."
