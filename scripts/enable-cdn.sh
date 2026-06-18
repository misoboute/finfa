#!/usr/bin/env bash
# Enable the Cloudflare CDN front — defeats IP-blocking by hiding the origin IP.
# Clients connect to Cloudflare; a tunnel connector dials OUT from this box and
# relays to the WS inbound, so your server IP is never exposed. Run this either
# proactively or the day a censor IP-blocks you. Full walkthrough: docs/cdn-cloudflare.md
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
source scripts/lib.sh
DC="docker compose"; docker info >/dev/null 2>&1 || DC="sudo docker compose"

[[ -f .env ]] || { err "run ./setup.sh first (.env missing)"; exit 1; }
command -v dig >/dev/null || { warn "Installing dnsutils (dig — needed to read the ECH key from DNS)"; sudo apt-get update -qq && sudo apt-get install -y dnsutils; }

step "Enable Cloudflare CDN front"
cat <<'EOF'
First, in the Cloudflare dashboard (see docs/cdn-cloudflare.md for click-by-click):
  1) Add your domain to a free Cloudflare account; point the registrar's
     nameservers at Cloudflare; wait until it shows "Active".
  2) Zero Trust -> Networks -> Tunnels -> Create a tunnel -> Cloudflared -> name it.
  3) Add a Public Hostname:
        Subdomain: (blank)   Domain: <your domain>
        Service -> Type: HTTP   URL: marzban:8080
  4) Copy the tunnel token (the long "eyJ..." string).
EOF
confirm "Done all four in the dashboard?" n || { note "Do those first, then re-run."; exit 0; }

DOMAIN="$(ask 'Your domain (e.g. example.com)' "$(grep -E '^CF_DOMAIN=' .env | cut -d= -f2-)")"
[[ -n "$DOMAIN" ]] || { err "domain required"; exit 1; }
TOKEN="$(ask_secret 'Paste the Cloudflare tunnel token (hidden)')"
[[ -n "$TOKEN" ]] || { err "token required"; exit 1; }
DEFIP="$(grep -E '^CF_CLEAN_IP=' .env | cut -d= -f2-)"; DEFIP="${DEFIP:-104.17.147.22,162.159.192.1}"
note "Clean Cloudflare edge IP(s) to pin, comma-separated — client links connect"
note "straight to these so DNS poisoning can't touch them. Defaults are commonly"
note "reachable; if they're throttled from your users' region, swap later + regen."
CLEANIP="$(ask 'Clean IP(s)' "$DEFIP")"

# Persist into .env (gitignored). Python avoids sed-escaping issues with the token.
DOMAIN="$DOMAIN" TOKEN="$TOKEN" CLEANIP="$CLEANIP" python3 - <<'PY'
import os, re
lines = open('.env').read().splitlines()
def setk(lines, k, v):
    out, done = [], False
    for l in lines:
        if re.match(rf'^{k}=', l): out.append(f'{k}={v}'); done = True
        else: out.append(l)
    if not done: out.append(f'{k}={v}')
    return out
lines = setk(lines, 'CF_DOMAIN', os.environ['DOMAIN'])
lines = setk(lines, 'CF_TUNNEL_TOKEN', os.environ['TOKEN'])
lines = setk(lines, 'CF_CLEAN_IP', os.environ['CLEANIP'])
open('.env', 'w').write('\n'.join(lines) + '\n')
PY
say ".env updated (CF_DOMAIN, CF_TUNNEL_TOKEN, CF_CLEAN_IP)."

step "Starting the tunnel connector"
$DC --profile cdn up -d cloudflared
note "waiting for the connector to register with Cloudflare..."
ok=0
for i in $(seq 1 20); do
  if $DC logs --tail 60 cloudflared 2>&1 | grep -qi 'Registered tunnel connection'; then ok=1; break; fi
  sleep 2
done
[[ $ok = 1 ]] && say "tunnel healthy (connections registered)." \
              || warn "couldn't confirm health yet — check: ./scripts/diagnose.sh cdn"

step "Wiring Marzban (CDN host + assigning users)"
python3 scripts/marzban.py set-ws-host --domain "$DOMAIN"
python3 scripts/marzban.py migrate-ws

step "End-to-end test through Cloudflare"
FIRST="$(python3 scripts/marzban.py list 2>/dev/null | awk 'NR==1{print $2}')"
if [[ -n "$FIRST" ]]; then
  ./scripts/diagnose.sh clienttest "$(python3 scripts/marzban.py link "$FIRST" | head -1)" || true
else
  note "No users yet — add one, then test:"
  note "  ./scripts/diagnose.sh clienttest \"\$(python3 scripts/marzban.py link NAME | head -1)\""
fi

step "Done — CDN front is live"
cat <<EOF
Clients now reach Cloudflare on a pinned clean IP, with the real SNI hidden by
ECH — that beats IP-blocking, DNS poisoning, AND SNI filtering at once.

  One user's link(s):   python3 scripts/marzban.py link NAME
  New user:             python3 scripts/marzban.py adduser NAME --save
  Many at once:         python3 scripts/marzban.py batch a b c --save
  Refresh everyone:     python3 scripts/marzban.py regen --save   (after an IP/ECH change)

Links pin CF_CLEAN_IP and embed the live ECH key (pulled from DNS each time).
If a pinned IP gets throttled from your region: edit CF_CLEAN_IP in .env + regen.
If ECH is ever unavailable for the zone: links still pin the IP (DNS-poison-proof)
but the SNI becomes visible — then rotate to a fresh domain on the same tunnel.
EOF
