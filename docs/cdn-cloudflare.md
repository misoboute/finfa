# Beating censorship — the Cloudflare CDN front (with clean-IP + ECH)

Reality is **DPI-resistant** but **direct**: clients connect to your server's raw
IP. A determined censor (Iran is the reference case) attacks in three escalating
ways, and this front defeats all three:

| Censor move | What it does | FINFA's counter |
|---|---|---|
| **IP block** | blacklists your VPS IP | **Cloudflare Tunnel** — origin IP never exposed; clients hit Cloudflare |
| **DNS poisoning** | resolves your domain to a sinkhole (e.g. `10.10.34.34`) | **pinned clean IP** in the config — no DNS lookup happens at all |
| **SNI filtering** | reads your domain out of the TLS handshake and kills it | **ECH** — the real domain is encrypted; only `cloudflare-ech.com` is on the wire |

```
  client ──TLS(ECH)+WebSocket──▶ Cloudflare edge ──tunnel──▶ cloudflared ──▶ Xray :8080 ──▶ internet
   (Iran)   to a PINNED clean IP   (can't blanket-block)    (outbound only)   (origin IP hidden)
            SNI on wire = cloudflare-ech.com (real domain encrypted inside)
```

Runs **alongside** Reality (which stays on :443 for anyone not IP-blocked). Needs a
**domain** (~$1–10/yr) on a **free** Cloudflare account that has **ECH enabled**
(Cloudflare publishes an `ech=` value in the domain's HTTPS DNS record).

## 1. Domain → Cloudflare (one time)
1. Register a cheap, **boring** domain (Namecheap, Porkbun, …) — not "vpn/free/proxy".
2. Free account at **dash.cloudflare.com** → **Add a site** → your domain → **Free**.
3. Set the domain's nameservers to the two Cloudflare gives you. Wait for **Active**.
4. Confirm ECH is on: `dig +short HTTPS yourdomain` should contain `ech=…`
   (Cloudflare enables it automatically for most free zones).

## 2. Create the tunnel
5. Cloudflare → **Zero Trust** (pick a team name + Free plan the first time).
6. **Networks → Tunnels → Create a tunnel → Cloudflared →** name it → Save.
7. **Copy the token** (the long `eyJ…` string) — don't run the shown command, FINFA runs the connector.
8. **Add a public hostname:** Subdomain blank · Domain = yours · Service **HTTP** `marzban:8080`.

## 3. Flip it on
```bash
./scripts/enable-cdn.sh
```
It asks for your domain, the tunnel token, and the **clean Cloudflare IP(s)** to
pin; brings up the `cloudflared` connector; wires the Marzban host; puts all users
on the WS path; checks that ECH is published; and runs an end-to-end test.

**Clean IPs:** any reachable Cloudflare edge IP routes to your tunnel by SNI/Host,
so you pin one (or a few, comma-separated in `CF_CLEAN_IP`) that aren't throttled
from your users' region. The defaults are common-clean starting points; if they're
slow/blocked, find a working one (community "clean IP" lists / scanners) and
`regen` (below).

## 4. Hand out configs (our own tooling — Marzban can't emit ECH links)
```bash
python3 scripts/marzban.py link NAME            # a user's link(s) — clean-IP + ECH, one per pinned IP
python3 scripts/marzban.py adduser NAME --save  # create one user + save its link(s)
python3 scripts/marzban.py batch a b c --save   # create many at once
python3 scripts/marzban.py regen --save         # reprint/refresh ALL users' links
```
The tool builds the `vless://` link itself: it pins `CF_CLEAN_IP`, sets the WS
host/SNI to your domain, and embeds the **current ECH key pulled live from DNS**
(`&ech=…`). v2rayNG / v2rayN / V2Box / Hiddify all parse it. Send links over a
**secure** channel only — never a monitored/domestic messenger.

## Operating notes
- **Health:** `./scripts/diagnose.sh cdn` — connector status + whether ECH is published.
- **End-to-end test:** `./scripts/diagnose.sh clienttest "$(python3 scripts/marzban.py link NAME | head -1)"`
  (it handles WS/ECH links); a match on your server's public IP = the whole path works.
- **ECH key rotation:** Cloudflare rotates the ECH key occasionally. Because the
  tool reads it from DNS at generation time, you just `regen --save` and re-hand
  links — no config surgery. (Clients can't fetch ECH themselves under DNS
  poisoning, so the key is embedded; hence the occasional refresh.)
- **Pinned IP throttled?** Put a fresh clean IP in `CF_CLEAN_IP` (.env) → `regen`.
- **ECH not available for your zone?** Links still pin the IP (DNS-poison-proof),
  but the SNI is visible again — rotate to a fresh domain on the **same** tunnel
  (`set-ws-host --domain NEW`) if that domain gets SNI-filtered.
- **Why a tunnel, not a proxied DNS record:** outbound-only, so the origin IP is
  never in any DNS record or directly reachable — and no inbound port/firewall changes.
- The WS inbound binds inside the container only; Cloudflare reaches it solely
  through the connector.
