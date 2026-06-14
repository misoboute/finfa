#!/usr/bin/env bash
# FINFA diagnostics — the playbook distilled from a real "everything went dark"
# incident. Most outages are one of: core too old for modern clients, a broken
# config, the panel down, or the firewall. This checks each fast.
#
# Usage:
#   ./scripts/diagnose.sh status            quick health (container, ports, core, config)
#   ./scripts/diagnose.sh logs              tail Xray access + error logs
#   ./scripts/diagnose.sh reality           scan error log for Reality rejections
#   ./scripts/diagnose.sh debug on|off      toggle Xray debug logging (restarts panel)
#   ./scripts/diagnose.sh clienttest LINK   GOLD TEST: connect through the tunnel
#                                           from the box itself using a vless:// link
#                                           (get one via: scripts/marzban.py link NAME)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
CFG="xray/xray_config.json"
DC="docker compose"; docker info >/dev/null 2>&1 || DC="sudo docker compose"
DKR="docker"; docker info >/dev/null 2>&1 || DKR="sudo docker"

cmd="${1:-status}"

case "$cmd" in
status)
  echo "== container =="
  $DKR ps --filter name=finfa-marzban --format '{{.Names}}  {{.Status}}' || true
  echo "== :443 listening on host =="
  (sudo ss -tulpn 2>/dev/null || ss -tuln) | grep ':443' || echo "  NOTHING on :443 (Reality down)"
  echo "== Xray core version (in container) =="
  $DKR exec finfa-marzban xray version 2>/dev/null | head -1 || echo "  cannot exec xray"
  echo "== config sanity =="
  if grep -q '__REALITY_' "$CFG"; then echo "  ✗ placeholders still present — run scripts/02-gen-reality-keys.sh"; else echo "  ✓ no placeholders"; fi
  grep -q 'geoip:private' "$CFG" && echo "  ✓ isolation block present" || echo "  ✗ ISOLATION BLOCK MISSING"
  echo "== recent accepted sessions =="
  $DKR exec finfa-marzban sh -c 'tail -n 200 /var/lib/marzban/access.log 2>/dev/null | grep -c accepted' 2>/dev/null \
    | sed 's/^/  accepted lines in last 200: /' || echo "  no access log yet"
  ;;
logs)
  echo "== access.log (tail) =="; $DKR exec finfa-marzban tail -n 30 /var/lib/marzban/access.log 2>/dev/null
  echo "== error.log (tail) ==";  $DKR exec finfa-marzban tail -n 30 /var/lib/marzban/error.log 2>/dev/null
  ;;
reality)
  echo "Scanning error.log for Reality rejections ('invalid connection' = client/core mismatch or bad params)..."
  $DKR exec finfa-marzban sh -c 'grep -i "reality\|invalid connection" /var/lib/marzban/error.log | tail -n 40' 2>/dev/null \
    || echo "none found (good, or error.log empty)"
  ;;
debug)
  mode="${2:-}"; [[ "$mode" == on || "$mode" == off ]] || { echo "usage: diagnose.sh debug on|off"; exit 1; }
  lvl=warning; [[ "$mode" == on ]] && lvl=debug
  sed -i "s/\"loglevel\": \"[a-z]*\"/\"loglevel\": \"$lvl\"/" "$CFG"
  $DC restart marzban >/dev/null
  echo "loglevel=$lvl applied + panel restarted. Reproduce, then read: diagnose.sh reality"
  [[ "$mode" == on ]] && echo "REMEMBER to run 'diagnose.sh debug off' when done."
  ;;
clienttest)
  link="${2:-}"; [[ -n "$link" ]] || { echo "usage: diagnose.sh clienttest 'vless://...'"; exit 1; }
  command -v xray/bin/xray >/dev/null 2>&1 || [[ -x xray/bin/xray ]] || { echo "xray/bin/xray missing — run scripts/fetch-xray.sh"; exit 1; }
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  # Build a minimal SOCKS->VLESS/Reality client config from the link.
  python3 - "$link" > "$tmp/client.json" <<'PY'
import sys, urllib.parse as u
l = sys.argv[1]
p = u.urlparse(l); q = dict(u.parse_qsl(p.query))
cfg = {
 "inbounds":[{"port":10808,"listen":"127.0.0.1","protocol":"socks","settings":{"udp":True}}],
 "outbounds":[{"protocol":"vless","settings":{"vnext":[{"address":p.hostname,"port":p.port or 443,
   "users":[{"id":p.username,"encryption":"none","flow":q.get("flow","")}]}]},
   "streamSettings":{"network":q.get("type","tcp"),"security":"reality","realitySettings":{
     "serverName":q.get("sni",""),"fingerprint":q.get("fp","chrome"),
     "publicKey":q.get("pbk",""),"shortId":q.get("sid",""),"spiderX":q.get("spx","")}}}]}
import json; print(json.dumps(cfg))
PY
  echo "Starting on-box client (SOCKS 127.0.0.1:10808)..."
  ./xray/bin/xray run -c "$tmp/client.json" >/dev/null 2>&1 &
  xpid=$!; sleep 2
  echo -n "egress IP via tunnel: "
  if curl -s --max-time 12 -x socks5h://127.0.0.1:10808 https://api.ipify.org; then
    echo "  <- if this is the SERVER's public IP, the tunnel works end-to-end."
  else
    echo "(failed) — tunnel did NOT establish. Check: core version (status), Reality params, clock skew."
  fi
  kill "$xpid" 2>/dev/null
  ;;
*)
  echo "usage: diagnose.sh {status|logs|reality|debug on|off|clienttest LINK}"; exit 1 ;;
esac
