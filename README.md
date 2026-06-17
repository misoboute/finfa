# FINFA — Free InterNet For All

A censorship-resistant VPN you can stand up on **one ordinary Ubuntu server** by
cloning this repo and running one script. It serves a **VLESS + Reality** tunnel
(DPI-resistant — it borrows a real TLS 1.3 site's handshake), with a web panel,
per-user quotas, a device-concurrency cap, optional Telegram management, and hard
network isolation so VPN users can reach the open internet and **nothing on your
box**.

> **Scope.** Reality is a *direct* path: clients connect to your server's raw IP.
> It defeats deep-packet inspection but **not** a plain IP block. When a censor
> blacklists your server's IP outright (Iran does this to VPS ranges), flip on the
> built-in **Cloudflare CDN front** (`./scripts/enable-cdn.sh`) — it hides your
> origin IP behind Cloudflare so blocking it is pointless. See
> [Beating IP blocks](#beating-ip-blocks-cloudflare) and
> [`docs/cdn-cloudflare.md`](docs/cdn-cloudflare.md).

## What you need

- A **VPS or server running Ubuntu** (22.04 or 24.04 tested), with a **public
  IPv4**.
- **Root/sudo** access over SSH.
- Minimum **1 GiB RAM**, **1 vCPU**, **~3 GiB free disk** (2 vCPU / 2 GiB is
  comfortable). FINFA runs resource-capped so it won't starve anything else on
  the box.
- **TCP 443 reachable** from the internet, plus your SSH port.
- A provider **web/VNC console** (almost all have one) as a lockout safety net.

Nothing else is required — the wizard installs Docker, downloads the Xray core,
generates keys and certs, and configures the firewall for you.

## Set it up

```bash
# on the server, as a sudo-capable user
git clone https://github.com/<you>/finfa.git
cd finfa
./setup.sh
```

The wizard will:

1. **Check** the host and install any missing prerequisites.
2. **Ask** for: your public IP (auto-detected), SSH port (auto-detected), panel
   port, admin password (auto-generated if you prefer), a camouflage SNI (it
   validates TLS 1.3 for you), a per-user device limit, and optional Telegram
   bot credentials.
3. Walk through each phase **with a confirmation before each one**: install
   Docker → fetch the Xray core → generate Reality keys → make the panel cert →
   build and start the stack → apply the firewall **behind a 5-minute
   auto-revert** (it makes you prove a fresh SSH login works before locking it
   in) → optionally create your first user and enable the device cap.

Re-running `./setup.sh` is safe: completed steps are detected and skipped.

## Day-to-day

```bash
# add a user (default: unlimited, no expiry). --gb / --days to limit. --save writes the link to secrets/
python3 scripts/marzban.py adduser alice --save
python3 scripts/marzban.py link alice          # print their vless:// link again
python3 scripts/marzban.py list                # all users + status

# reach the panel from your laptop (loopback-only by design):
ssh -L 8000:127.0.0.1:8000 -p <ssh-port> <user>@<server-ip>
#   then open https://127.0.0.1:8000/dashboard  (accept the private-CA warning)

# something broke? run the diagnostics playbook:
./scripts/diagnose.sh status        # container, :443, core version, config sanity
./scripts/diagnose.sh clienttest "$(python3 scripts/marzban.py link alice)"   # end-to-end test
```

Hand users a config with the platform-by-platform guide in
[`docs/CONNECT-GUIDE.md`](docs/CONNECT-GUIDE.md) (drop their link in place of
`{{CONFIG_LINK}}`). **Send links privately — never via insecure or monitored channels (SMS, untrusted messengers).**

## Beating IP blocks (Cloudflare)

Reality hides *what* your traffic is, but not *where* it goes — a censor can still
blacklist your server's raw IP (Iran does this routinely to datacenter ranges).
FINFA ships an optional **Cloudflare Tunnel** front that settles this: clients
connect to Cloudflare's IPs and an **outbound-only** connector relays to your
origin, so your server IP is never exposed and blocking it does nothing.

You need a cheap domain on a free Cloudflare account, then:

```bash
./scripts/enable-cdn.sh                       # prompts for domain + tunnel token, wires it all up
python3 scripts/marzban.py link NAME --ws     # hand each user their CDN link
```

Click-by-click (domain → tunnel → token) is in
[`docs/cdn-cloudflare.md`](docs/cdn-cloudflare.md). It runs **alongside** Reality,
so users who aren't IP-blocked keep the direct path. If a domain itself ever gets
SNI-blocked, point another at the same tunnel — rotating a cheap domain beats
moving servers.

## How it's isolated (the important part)

- **Xray routing block** (`xray/xray_config.json`): VPN users egress to the open
  internet and are blackholed from `geoip:private` + loopback — they can't reach
  your panel or anything else on the host. *Do not weaken this.*
- **Host firewall** (`firewall/`): default-drop inbound; only your SSH port and
  `443` are open. Applied behind an anti-lockout auto-revert.
- **Panel** is published to `127.0.0.1` only — admin via SSH tunnel.
- **Docker** bridge networking, no `--privileged`, no `network_mode: host`,
  with CPU/memory caps.

See [`RUNBOOK.md`](RUNBOOK.md) for the phase-by-phase manual walkthrough (what the
wizard automates) and [`docs/verify-isolation.md`](docs/verify-isolation.md) for
the isolation hard-gate you should run before real handoffs.

## Layout

```
finfa/
├─ setup.sh                  # the wizard — start here
├─ README.md  ·  RUNBOOK.md  # this · phase-by-phase manual + diagnostics
├─ docker-compose.yml        # Marzban (panel localhost + Reality 443) + watcher + cloudflared
├─ marzban.Dockerfile        # Marzban image + our private panel CA
├─ .env.example              # config template (setup.sh writes .env for you)
├─ xray/
│  ├─ xray_config.json       # Reality + (optional) WS inbound + CRITICAL isolation block
│  └─ bin/xray-wrap.sh       # core shim (xray binary is fetched, not committed)
├─ firewall/                 # default-drop ruleset + anti-lockout apply/persist
├─ scripts/
│  ├─ lib.sh                 # tiny prompt/confirm helpers
│  ├─ 00-recon.sh            # read-only host inventory
│  ├─ 01-install-docker.sh   # official Docker install
│  ├─ 02-gen-reality-keys.sh # x25519 keypair + shortId → config + secrets/
│  ├─ 03-gen-panel-cert.sh   # private CA + panel cert
│  ├─ 04-up.sh               # build + compose up
│  ├─ fetch-xray.sh          # download current Xray core
│  ├─ validate-sni.sh        # TLS 1.3 check for a camouflage SNI
│  ├─ enable-cdn.sh          # turn on the Cloudflare CDN front (beats IP blocks)
│  ├─ marzban.py             # ops CLI: set-host / set-ws-host / migrate-ws / adduser / link / list
│  └─ diagnose.sh            # status / logs / reality / cdn / debug / clienttest
├─ concurrency-watcher/      # per-user device-cap container
├─ docs/                     # CONNECT-GUIDE.md · verify-isolation.md · cdn-cloudflare.md
└─ secrets/                  # keys, certs, links (gitignored, 0600)
```

## Non-negotiable rules

- Never expose the panel publicly — loopback + SSH tunnel only.
- Never weaken the `geoip:private` routing block.
- Never apply a firewall change without the auto-revert + fresh-session test.
- No `--privileged`, no `network_mode: host`.
- Keep `secrets/` and `.env` private (0600, gitignored).

## License

Copyright (C) 2026 FINFA contributors. Released under the **GNU General Public
License v3.0** — see [`LICENSE`](LICENSE). You may use, study, share, and modify
it; derivatives must stay under the same license.
