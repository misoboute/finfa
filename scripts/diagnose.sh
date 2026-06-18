#!/usr/bin/env bash
# FINFA diagnostics — the playbook distilled from a real "everything went dark"
# incident. Most outages are one of: core too old for modern clients, a broken
# config, the panel down, the firewall, or (after an IP block) the CDN tunnel.
#
# Usage:
#   ./scripts/diagnose.sh status            quick health (container, ports, core, config)
#   ./scripts/diagnose.sh logs              tail Xray access + error logs
#   ./scripts/diagnose.sh reality           scan error log for Reality rejections
#   ./scripts/diagnose.sh cdn               Cloudflare tunnel connector health
#   ./scripts/diagnose.sh debug on|off      toggle Xray debug logging (restarts panel)
#   ./scripts/diagnose.sh clienttest LINK   GOLD TEST: connect from the box itself
#                                           using a vless:// link (Reality OR WS/CDN).
#                                           Get one via: scripts/marzban.py link NAME [--ws]
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
  if grep -q '__REALITY_\|__CDN_PATH__' "$CFG"; then echo "  ✗ placeholders still present — run scripts/02-gen-reality-keys.sh"; else echo "  ✓ no placeholders"; fi
  grep -q 'geoip:private' "$CFG" && echo "  ✓ isolation block present" || echo "  ✗ ISOLATION BLOCK MISSING"
  echo "== CDN front =="
  $DKR ps --filter name=finfa-cloudflared --format '{{.Names}}  {{.Status}}' | grep -q . \
    && echo "  cloudflared running (run 'diagnose.sh cdn' for tunnel health)" || echo "  not enabled (plain Reality-direct)"
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
cdn)
  echo "== cloudflared container =="
  $DKR ps --filter name=finfa-cloudflared --format '{{.Names}}  {{.Status}}' | sed 's/^/  /' || echo "  not running"
  echo "== connector log (want 'Registered tunnel connection') =="
  $DKR logs --tail 40 finfa-cloudflared 2>&1 | grep -iE 'registered tunnel connection|error|failed|unauthorized' | tail -8 | sed 's/^/  /' \
    || echo "  no logs (is the cdn profile up? scripts/enable-cdn.sh)"
  echo "== config + ECH (SNI hiding) =="
  DOMAIN=$(grep -E '^CF_DOMAIN=' .env 2>/dev/null | cut -d= -f2-)
  CLEAN=$(grep -E '^CF_CLEAN_IP=' .env 2>/dev/null | cut -d= -f2-)
  echo "  domain=${DOMAIN:-<unset>}  clean_ip=${CLEAN:-<unset>}"
  if [ -n "$DOMAIN" ]; then
    if dig +short HTTPS "$DOMAIN" 2>/dev/null | grep -q 'ech='; then
      echo "  ✓ ECH published — real SNI stays hidden (links embed it)"
    else
      echo "  ✗ no ECH for $DOMAIN — SNI is visible; enable ECH on the zone or expect SNI-filter risk"
    fi
  fi
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
  [[ -x xray/bin/xray ]] || { echo "xray/bin/xray missing — run scripts/fetch-xray.sh"; exit 1; }
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  # Build a SOCKS->VLESS client config from the link — handles Reality and WS/TLS (CDN).
  python3 - "$link" > "$tmp/client.json" <<'PY'
import sys, json, urllib.parse as u
p = u.urlparse(sys.argv[1]); q = dict(u.parse_qsl(p.query))
sec, typ = q.get("security",""), q.get("type","tcp")
out = {"protocol":"vless","settings":{"vnext":[{"address":p.hostname,"port":p.port or 443,
       "users":[{"id":p.username,"encryption":"none"}]}]}}
if sec == "reality":
    out["settings"]["vnext"][0]["users"][0]["flow"] = q.get("flow","")
    out["streamSettings"] = {"network":typ,"security":"reality","realitySettings":{
        "serverName":q.get("sni",""),"fingerprint":q.get("fp","chrome"),
        "publicKey":q.get("pbk",""),"shortId":q.get("sid",""),"spiderX":q.get("spx","")}}
else:  # xhttp/ws + tls (Cloudflare CDN path)
    ss = {"network":typ,"security":"tls","tlsSettings":{"serverName":q.get("sni","")}}
    ts = {"path":q.get("path","/"),"headers":{"Host":q.get("host","")}}
    ss["xhttpSettings" if typ == "xhttp" else "wsSettings"] = ts
    out["streamSettings"] = ss
print(json.dumps({"inbounds":[{"port":10808,"listen":"127.0.0.1","protocol":"socks",
    "settings":{"udp":True}}],"outbounds":[out]}))
PY
  echo "Starting on-box client (SOCKS 127.0.0.1:10808)..."
  ./xray/bin/xray run -c "$tmp/client.json" >/dev/null 2>&1 &
  xpid=$!; sleep 3
  echo -n "egress IP via tunnel: "
  if curl -s --max-time 20 -x socks5h://127.0.0.1:10808 https://api.ipify.org; then
    echo "  <- if this is the SERVER's public IP, the path works end-to-end."
  else
    echo "(failed) — check: core version (status), params, clock skew; for CDN check 'diagnose.sh cdn'."
  fi
  kill "$xpid" 2>/dev/null
  ;;
*)
  echo "usage: diagnose.sh {status|logs|reality|cdn|debug on|off|clienttest LINK}"; exit 1 ;;
esac
