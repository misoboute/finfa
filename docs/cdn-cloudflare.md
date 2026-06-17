# Beating IP blocks — the Cloudflare CDN front

Reality is **DPI-resistant** but **direct**: clients connect to your server's raw
IP. A censor who simply **blacklists that IP** (as Iran does to VPS ranges) cuts
everyone off, and no camouflage helps. The fix is to stop exposing the IP at all:
put a **Cloudflare Tunnel** in front. Clients connect to **Cloudflare's** IPs;
a connector dials *outbound* from your box to Cloudflare and relays traffic in.
Your origin IP is never seen by clients or the censor, so blocking it is moot —
they'd have to block Cloudflare itself.

```
  client ──TLS+WebSocket──▶ Cloudflare edge ──tunnel──▶ cloudflared ──▶ Xray :8080 (VLESS-WS) ──▶ internet
   (Iran)                  (unblockable-ish)          (outbound only)        (origin, IP hidden)
```

This runs **alongside** Reality (which stays on :443 for anyone not IP-blocked).
It needs a **domain** (~$1–10/yr) on a **free** Cloudflare account.

## 1. Domain → Cloudflare (one time)
1. Register a cheap, **boring** domain (Namecheap, Porkbun, …) — not anything like
   "vpn/free/proxy". If a censor later SNI-blocks it, you just rotate to another.
2. Free account at **dash.cloudflare.com** → **Add a site** → your domain → **Free**.
3. Cloudflare gives you **two nameservers**. At your registrar, set the domain's
   nameservers to those. Wait until Cloudflare shows the domain **Active**.

## 2. Create the tunnel
4. Cloudflare → **Zero Trust** (pick a team name + Free plan the first time).
5. **Networks → Tunnels → Create a tunnel → Cloudflared →** name it (e.g. `finfa`) → Save.
6. On the install screen, just **copy the token** (the long `eyJ…` string). You
   don't need to run the shown command — FINFA runs the connector for you.
7. **Add a public hostname:**
   - **Subdomain:** blank   **Domain:** your domain
   - **Service → Type:** `HTTP`   **URL:** `marzban:8080`
   - Save. (`marzban:8080` is the WS inbound, reachable inside FINFA's Docker network.)

## 3. Flip it on
```bash
./scripts/enable-cdn.sh
```
It asks for your domain + the token, brings up the `cloudflared` connector,
points Marzban's share-links at your domain, assigns all users to the WS path,
and runs an end-to-end test through Cloudflare.

## 4. Hand out the new configs
Each user needs their **CDN** link (the old Reality link won't reach them if the
IP is blocked):
```bash
python3 scripts/marzban.py link NAME --ws      # one user's CDN link
python3 scripts/marzban.py adduser NAME --save # new users get both paths automatically
```
Send links over a **secure** channel only — never a monitored/domestic messenger.

## Operating notes
- **Health:** `./scripts/diagnose.sh cdn` (want "Registered tunnel connection").
- **Test end-to-end:** `./scripts/diagnose.sh clienttest "$(python3 scripts/marzban.py link NAME --ws)"`
  — a match on your server's public IP means the whole path works.
- **Domain SNI-blocked?** Add another domain to the **same** tunnel (step 1–2,
  reuse the tunnel), then `python3 scripts/marzban.py set-ws-host --domain NEW`
  and re-hand links. Rotating a domain ≫ rebuilding a server.
- **Why a tunnel, not a proxied DNS record:** the tunnel is *outbound-only*, so
  the origin IP is never in any DNS record or reachable directly — maximum hiding,
  and no inbound port/firewall changes.
- The WS inbound binds inside the container only (never published to the host or
  internet); Cloudflare reaches it solely through the connector.
