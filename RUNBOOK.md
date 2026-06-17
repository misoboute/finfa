# FINFA — Operator Runbook (what the wizard does, and how to do it by hand)

`./setup.sh` automates everything below with prompts and confirmations. This
runbook documents each phase so you can understand, audit, or run it manually.
**Work phase by phase; the firewall phase has an anti-lockout safety you must
not skip.**

> Reality is a **direct** path (client → raw VPS IP). It is DPI-resistant but
> does not defeat a plain IP block. If a censor blacklists your VPS IP, enable the
> **Cloudflare CDN front** (Phase 10) to hide the origin. Everyone whose network
> can route to the IP also gets the fully DPI-resistant direct tunnel.

---

## Phase 0 — Recon (read-only)
`./scripts/00-recon.sh` — inventories OS, CPU/RAM/disk, listening sockets,
Docker, firewall. Makes no changes. Note anything bound to `0.0.0.0` (exposure)
and any co-resident workload you must not disturb.

## Phase 1 — Host prep
1. **Snapshot the VPS** and confirm your provider's **web/VNC console** works —
   your lockout safety net.
2. Keep a **second** SSH session open through the firewall phase.
3. Install Docker: `sudo ./scripts/01-install-docker.sh`
4. Fetch the current Xray core: `./scripts/fetch-xray.sh`

## Phase 2 — Config
`cp .env.example .env` and set a strong `SUDO_PASSWORD` (+ matching
`MARZBAN_ADMIN_PASSWORD`). The wizard generates these for you.

## Phase 3 — Reality keys + camouflage SNI
1. Pick and validate a camouflage SNI: `./scripts/validate-sni.sh www.example.com`
   (TLS 1.3, popular, innocuous, reachable from your users' region, not your own brand).
2. `REALITY_SNI=www.example.com ./scripts/02-gen-reality-keys.sh`
   — private key → `secrets/reality.txt` (0600); public key + shortId printed.

## Phase 4 — Panel cert + bring-up
1. `./scripts/03-gen-panel-cert.sh` — private CA + signed panel cert (Marzban
   refuses self-signed certs and won't bind for port-publish without a CA-signed one).
2. `./scripts/04-up.sh` — builds the image (installs the CA) and starts Marzban:
   panel on `127.0.0.1:PANEL_PORT`, Reality on `:443`, resource caps applied.
3. Set the share-link Host so client links carry your IP + SNI:
   `python3 scripts/marzban.py set-host --address <SERVER_IP>`

> CHECKPOINT — panel reachable only via SSH tunnel, admin login works, caps in place.

## Phase 5 — Firewall (ANTI-LOCKOUT)
1. `sudo SSH_PORT=<your ssh port> ./firewall/apply-firewall.sh`
   — applies a default-drop inbound ruleset (only your SSH port + 443) behind a
   **5-minute auto-revert**.
2. **Open a brand-new SSH session and confirm you can log in.** Then, within the
   window: `sudo touch /run/finfa-fw-confirmed`
3. Persist across reboot: `sudo ./firewall/persist-firewall.sh`

## Phase 6 — Routing isolation (HARD GATE)
The block is already in `xray/xray_config.json` (`geoip:private` + loopback →
blackhole). Run every check in `docs/verify-isolation.md` from a tunneled test
client. **All three must pass** (panel unreachable, internals unreachable, open
internet works) before you create real users.

## Phase 7 — Users + concurrency cap
1. Create users: `python3 scripts/marzban.py adduser NAME [--gb N] [--days N] [--save]`
   (default unlimited, no expiry). Print a link later with `... link NAME`.
2. Enable the per-user device cap (start in dry-run via `WATCH_DRY_RUN=true`):
   `docker compose --profile watcher up -d`. Watch: `docker compose logs -f watcher`.
   Connect one user from two IPs → expect `CAP TRIPPED`. Flip to `false` to enforce.

## Phase 8 — Handoff
Share each user's link privately. The Persian/per-platform client guide template
is `docs/CONNECT-GUIDE.md` (`{{CONFIG_LINK}}` placeholder). Send the link and any
password on **separate** channels; never via insecure or monitored channels (SMS, untrusted messengers).

## Phase 9 — Telegram (optional)
Set `TELEGRAM_API_TOKEN` (from @BotFather) and `TELEGRAM_ADMIN_ID` (from
@userinfobot) in `.env`, then `docker compose up -d` — Marzban's built-in admin
bot activates. Manage users from your phone.

## Phase 10 — Cloudflare CDN front (optional; the answer to an IP block)
When a censor blacklists your VPS IP, Reality can't help (the block is at the IP
layer). Front the service with a **Cloudflare Tunnel** so clients hit Cloudflare,
not your IP — the origin is reached only by an outbound connector and is never
exposed. Get a cheap domain on a free Cloudflare account, create a tunnel with a
public hostname (`<domain>` → HTTP `marzban:8080`), then:
`./scripts/enable-cdn.sh` (prompts for domain + token, wires the WS host, assigns
users, tests end-to-end). Hand out CDN links with
`python3 scripts/marzban.py link NAME --ws`. Runs alongside Reality. Full
click-by-click: `docs/cdn-cloudflare.md`. If a domain gets SNI-blocked, point
another at the same tunnel (`set-ws-host --domain NEW`) — cheaper than moving box.

---

## Diagnostics
`./scripts/diagnose.sh status|logs|reality|cdn|debug on|off|clienttest LINK`.
Most outages are: core too old for modern clients, a broken config, the panel
down, the firewall, or (after an IP block) the CDN tunnel. `clienttest` connects
through the tunnel from the box itself — the decisive end-to-end test; it handles
both Reality and WS/CDN links. See comments in the script.

## Rollback
- Stop stack: `docker compose down` (keeps the data volume).
- Revert firewall (surgical, Docker-safe): `sudo nft delete table inet finfa`.
- Worst case: restore the VPS snapshot from Phase 1.
