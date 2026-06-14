#!/usr/bin/env bash
# FINFA setup wizard — pull the repo, run this, answer the prompts. It stands up
# the whole VLESS+Reality stack with checkpoints. Safe to re-run: it skips steps
# already done. Run as a normal sudo-capable user (it calls sudo where needed).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"; cd "$ROOT"
source scripts/lib.sh

DKR="docker"; docker info >/dev/null 2>&1 || DKR="sudo docker"
DC="$DKR compose"

banner() {
  cat <<'EOF'
  ┌───────────────────────────────────────────────┐
  │   FINFA — Free InterNet For All  ·  setup      │
  │   VLESS + Reality, isolated, single-box VPN    │
  └───────────────────────────────────────────────┘
EOF
}

# ── Preflight ───────────────────────────────────────────────────────────────
preflight() {
  step "Preflight"
  [[ "$(id -u)" -eq 0 ]] && warn "Running as root. Fine, but normally you run as a sudo user."
  . /etc/os-release 2>/dev/null || true
  [[ "${ID:-}" == ubuntu ]] || warn "Tested on Ubuntu; '${ID:-unknown}' may need tweaks."
  local miss=()
  for c in curl python3 openssl unzip sudo; do command -v "$c" >/dev/null || miss+=("$c"); done
  if ((${#miss[@]})); then
    warn "Installing missing prerequisites: ${miss[*]}"
    sudo apt-get update -qq && sudo apt-get install -y "${miss[@]}"
  fi
  local mem_gb cores disk_gb
  mem_gb=$(awk '/MemTotal/{printf "%.1f",$2/1024/1024}' /proc/meminfo)
  cores=$(nproc); disk_gb=$(df -BG --output=avail / | tail -1 | tr -dc 0-9)
  note "Host: ${cores} vCPU, ${mem_gb} GiB RAM, ${disk_gb} GiB free on /"
  awk "BEGIN{exit !($mem_gb < 0.9)}" && warn "Under 1 GiB RAM — Marzban+Xray may be tight."
  (( disk_gb < 3 )) && warn "Under 3 GiB free — image + core need ~2 GiB."
  say "Preflight OK."
}

# ── Collect configuration ───────────────────────────────────────────────────
collect() {
  step "Configuration"
  DETECT_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null \
            || curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null || echo '')"
  SERVER_IP="$(ask 'Public IP of this server (clients connect here)' "${DETECT_IP}")"
  DETECT_SSH="$(awk '{print $4}' <<<"${SSH_CONNECTION:-}")"; DETECT_SSH="${DETECT_SSH:-22}"
  SSH_PORT="$(ask 'Your SSH port (kept open by the firewall — get this wrong and you lock yourself out)' "$DETECT_SSH")"
  PANEL_PORT="$(ask 'Panel port (loopback only)' '8000')"
  ADMIN_USER="$(ask 'Panel admin username' 'admin')"
  local gen; gen="$(genpw)"
  ADMIN_PASS="$(ask 'Panel admin password (Enter = generate a strong one)' "$gen")"

  echo; note "Pick a camouflage SNI — a real, popular HTTPS site (TLS 1.3) that is"
  note "reachable where your users are and is NOT your own brand. Reality borrows its"
  note "TLS handshake, so the more boring and widely-visited, the better."
  local sni_choices=( www.samsung.com www.bing.com www.microsoft.com dl.google.com www.amazon.com www.cloudflare.com )
  local n=${#sni_choices[@]} idx=1
  for s in "${sni_choices[@]}"; do printf '   %d) %s\n' "$idx" "$s"; idx=$((idx+1)); done
  printf '   %d) enter your own domain\n' "$idx"
  while :; do
    local pick; pick="$(ask "Choose 1-$idx, or just type a domain" '1')"
    if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick>=1 && pick<=n )); then
      REALITY_SNI="${sni_choices[pick-1]}"
    elif [[ "$pick" == "$idx" ]]; then
      REALITY_SNI="$(ask 'Your camouflage domain (e.g. www.example.com)' '')"
    else
      REALITY_SNI="$pick"     # typed a domain directly
    fi
    [[ -n "$REALITY_SNI" ]] || { warn "empty — pick again"; continue; }
    note "Validating $REALITY_SNI ..."
    if ./scripts/validate-sni.sh "$REALITY_SNI" | grep -q 'negotiates TLS 1.3'; then
      say "  $REALITY_SNI negotiates TLS 1.3 — good."; break
    fi
    confirm "  $REALITY_SNI failed the TLS 1.3 check. Use it anyway?" n && break
  done

  IP_LIMIT="$(ask 'Max simultaneous devices per user (concurrency cap)' '3')"

  echo; note "Optional Telegram admin bot (manage users from your phone). Leave blank to skip."
  TG_TOKEN="$(ask 'Telegram bot token (@BotFather)' '')"
  TG_ADMIN=''
  [[ -n "$TG_TOKEN" ]] && TG_ADMIN="$(ask 'Your Telegram numeric admin id (@userinfobot)' '')"

  echo
  say "Summary:"
  cat <<EOF
  server IP    : $SERVER_IP
  ssh port     : $SSH_PORT   (firewall keeps this + 443 open)
  panel port   : 127.0.0.1:$PANEL_PORT  (SSH-tunnel only)
  admin        : $ADMIN_USER
  camouflage   : $REALITY_SNI
  device cap   : $IP_LIMIT per user
  telegram bot : $([[ -n "$TG_TOKEN" ]] && echo enabled || echo disabled)
EOF
  confirm "Proceed with these settings?" || { err "Aborted."; exit 1; }
}

write_env() {
  step "Writing .env"
  [[ -f .env ]] && { cp .env ".env.bak.$(date +%s)"; note "backed up existing .env"; }
  ADMIN_USER="$ADMIN_USER" ADMIN_PASS="$ADMIN_PASS" PANEL_PORT="$PANEL_PORT" \
  IP_LIMIT="$IP_LIMIT" TG_TOKEN="$TG_TOKEN" TG_ADMIN="$TG_ADMIN" \
  python3 - <<'PY'
import os
src=open('.env.example').read().splitlines()
ov={'PANEL_PORT':os.environ['PANEL_PORT'],'UVICORN_PORT':os.environ['PANEL_PORT'],
    'SUDO_USERNAME':os.environ['ADMIN_USER'],'SUDO_PASSWORD':os.environ['ADMIN_PASS'],
    'MARZBAN_ADMIN_USERNAME':os.environ['ADMIN_USER'],'MARZBAN_ADMIN_PASSWORD':os.environ['ADMIN_PASS'],
    'WATCH_IP_LIMIT':os.environ['IP_LIMIT'],
    'TELEGRAM_API_TOKEN':os.environ['TG_TOKEN'],'TELEGRAM_ADMIN_ID':os.environ['TG_ADMIN']}
out=[]
for l in src:
    k=l.split('=',1)[0] if '=' in l and not l.lstrip().startswith('#') else None
    out.append(f'{k}={ov[k]}' if k in ov else l)
open('.env','w').write('\n'.join(out)+'\n')
os.chmod('.env',0o600)
PY
  say ".env written (0600)."
}

# ── Phases ──────────────────────────────────────────────────────────────────
phase_docker() {
  if docker compose version >/dev/null 2>&1 || sudo docker compose version >/dev/null 2>&1; then
    say "Docker + compose already installed — skipping."; return
  fi
  gate "Install Docker Engine + compose plugin (official apt repo)?" || return
  sudo ./scripts/01-install-docker.sh
}

phase_core() {
  if [[ -x xray/bin/xray ]]; then
    say "Xray core present ($(./xray/bin/xray version 2>/dev/null | head -1)) — skipping."
    confirm "  Re-download the latest anyway?" n || return
  else
    gate "Download the current Xray core (~35 MB)?" || return
  fi
  ./scripts/fetch-xray.sh
}

phase_keys() {
  if ! grep -q '__REALITY_' xray/xray_config.json; then
    say "Reality keys already injected — skipping."; return
  fi
  gate "Generate Reality keypair + inject config (SNI=$REALITY_SNI)?" || return
  REALITY_SNI="$REALITY_SNI" ./scripts/02-gen-reality-keys.sh
}

phase_cert() {
  if [[ -f secrets/panel-tls/panel.crt ]]; then
    say "Panel cert already present — skipping."; return
  fi
  gate "Generate the private CA + panel TLS cert?" || return
  ./scripts/03-gen-panel-cert.sh
}

phase_up() {
  gate "Build the image and bring up Marzban (panel + Reality)?" || return
  SERVER_IP="$SERVER_IP" ./scripts/04-up.sh
  note "Verifying admin login via API..."
  if python3 scripts/marzban.py list >/dev/null 2>&1; then
    say "Admin login OK."
  else
    warn "Could not authenticate yet. If the image didn't auto-create the admin, run:"
    warn "  $DC exec marzban marzban-cli admin create --sudo --username $ADMIN_USER"
  fi
  gate "Configure the share-link Host (so client links carry $SERVER_IP + SNI)?" || return
  python3 scripts/marzban.py set-host --address "$SERVER_IP" || warn "set-host failed; set the Host manually in the panel."
}

phase_firewall() {
  step "Firewall (anti-lockout)"
  warn "This applies a default-drop inbound ruleset (keeps SSH:$SSH_PORT and 443)."
  warn "It auto-reverts in 5 minutes unless you confirm a fresh SSH login works."
  gate "Apply the firewall now?" || { note "Skipped — do it later with firewall/apply-firewall.sh"; return; }
  sudo SSH_PORT="$SSH_PORT" ./firewall/apply-firewall.sh 300
  echo
  warn "NOW: open a SEPARATE terminal and run:  ssh -p $SSH_PORT <user>@$SERVER_IP"
  warn "Confirm you can log in. Do NOT close this session until you have."
  if confirm "Did a fresh SSH session log in successfully?" n; then
    sudo touch /run/finfa-fw-confirmed
    say "Locked in. Persisting across reboot."
    sudo ./firewall/persist-firewall.sh
  else
    warn "Not confirmed — the ruleset will auto-revert shortly. Re-run later when ready."
  fi
}

phase_isolation() {
  step "Isolation hard-gate (manual)"
  note "Before handing configs to real people, prove a VPN user can reach the open"
  note "internet and NOTHING inside the box. From a tunneled test client, run the"
  note "checks in docs/verify-isolation.md (server IP $SERVER_IP, panel $PANEL_PORT)."
  note "Server-side quick check now:"
  ./scripts/diagnose.sh status || true
}

phase_users() {
  if confirm "Create a first VPN user now?" n; then
    local name; name="$(ask 'Username' 'testuser')"
    python3 scripts/marzban.py adduser "$name" --save || warn "adduser failed."
    note "More users any time:  python3 scripts/marzban.py adduser NAME --save"
  fi
  if confirm "Enable the per-user device cap (watcher) now?" n; then
    $DC --profile watcher up -d watcher && say "Watcher running (limit=$IP_LIMIT)."
  fi
}

summary() {
  step "Done"
  cat <<EOF
FINFA is up.

  Panel : https://127.0.0.1:${PANEL_PORT}/dashboard  via
          ssh -L ${PANEL_PORT}:127.0.0.1:${PANEL_PORT} -p ${SSH_PORT} <user>@${SERVER_IP}
          (accept the private-CA warning; login: ${ADMIN_USER})

  Add a user      : python3 scripts/marzban.py adduser NAME --save
  Get a link      : python3 scripts/marzban.py link NAME
  Client guide    : docs/CONNECT-GUIDE.md  (paste a link in for ${_C_B}{{CONFIG_LINK}}${_C_0})
  Diagnose        : ./scripts/diagnose.sh status
  Isolation gate  : docs/verify-isolation.md  (run before real handoffs)

Secrets (0600, gitignored): secrets/reality.txt, secrets/panel-tls/, .env
EOF
}

main() {
  banner
  preflight
  collect
  write_env
  phase_docker
  phase_core
  phase_keys
  phase_cert
  phase_up
  phase_firewall
  phase_isolation
  phase_users
  summary
}
main "$@"
