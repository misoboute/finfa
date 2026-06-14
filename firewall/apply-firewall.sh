#!/usr/bin/env bash
# Apply the FINFA nftables ruleset BEHIND a timed auto-revert, so a mistake
# cannot lock you out. After applying, you MUST open a FRESH SSH session and
# confirm it works, then run the printed confirm command within the window.
#
# Usage:  sudo SSH_PORT=22 ./firewall/apply-firewall.sh [revert_seconds]
#   SSH_PORT defaults to 22; setup.sh passes the auto-detected port.
set -euo pipefail

REVERT_SECONDS="${1:-300}"
SSH_PORT="${SSH_PORT:-22}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$HERE/nftables-finfa.nft"
RENDERED="$HERE/nftables-finfa.rendered.nft"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$HERE/backup-$STAMP.nft"
CONFIRM="/run/finfa-fw-confirmed"

if [[ $EUID -ne 0 ]]; then echo "Run with sudo." >&2; exit 1; fi
command -v nft >/dev/null || { echo "Installing nftables..."; apt-get update -qq && apt-get install -y nftables; }

echo "==> Rendering ruleset with SSH port $SSH_PORT"
sed "s/__SSH_PORT__/${SSH_PORT}/g" "$TEMPLATE" > "$RENDERED"

echo "==> Backing up current ruleset to $BACKUP"
nft list ruleset > "$BACKUP"

echo "==> Scheduling auto-revert in ${REVERT_SECONDS}s unless confirmed"
rm -f "$CONFIRM"
# Detached so it survives this script and your SSH session dropping.
setsid bash -c "
  sleep ${REVERT_SECONDS}
  if [[ ! -f '$CONFIRM' ]]; then
    # Surgical revert: remove ONLY our table. Our apply merely ADDS
    # 'table inet finfa', so deleting it restores the prior inbound state
    # without flushing/round-tripping Docker's own nft/iptables tables.
    nft delete table inet finfa 2>/dev/null || true
    logger -t finfa-fw 'AUTO-REVERTED firewall: deleted table inet finfa (no confirmation within ${REVERT_SECONDS}s)'
  fi
" >/dev/null 2>&1 < /dev/null &

echo "==> Applying FINFA ruleset (idempotent)"
nft list table inet finfa >/dev/null 2>&1 && nft delete table inet finfa
nft -f "$RENDERED"

echo
echo "================================================================"
echo " FINFA firewall APPLIED (SSH allowed on port ${SSH_PORT})."
echo " Auto-revert in ${REVERT_SECONDS}s unless you confirm."
echo
echo " 1) Open a BRAND-NEW SSH session to this box RIGHT NOW and verify"
echo "    you can log in. (Keep this session open as a fallback.)"
echo
echo " 2) If the new session works, lock it in within the window:"
echo "        sudo touch $CONFIRM"
echo
echo " 3) If you are locked out, DO NOTHING — rules auto-revert and your"
echo "    provider's web/VNC console remains available."
echo
echo " After confirming, persist across reboot: sudo ./firewall/persist-firewall.sh"
echo "================================================================"
