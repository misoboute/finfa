#!/usr/bin/env python3
"""FINFA ops CLI — stdlib only (runs on a bare Ubuntu with python3).

Uses Marzban as the user/Xray backend, but generates share links OURSELVES so we
can embed the things Marzban's link generator can't: a pinned Cloudflare "clean
IP" (defeats DNS poisoning) and the ECH config (defeats SNI filtering). The ECH
key is pulled live from DNS at generation time, so links are always current.

Config (in .env): CF_DOMAIN, CF_CLEAN_IP (comma-separated edge IPs). When both
are set, the tool is in "CDN mode" and emits WS+TLS+ECH links pinned to those IPs.
Otherwise it falls back to the plain Reality link from Marzban's subscription.

Subcommands:
  wait                          block until the panel answers (setup.sh)
  set-host --address IP         configure the VLESS-Reality (direct) Host
  set-ws-host [--domain D]      configure the VLESS-WS (CDN) Host
  migrate-ws                    put ALL users on the WS inbound too (UUIDs kept)
  adduser NAME [--gb N --days N --save]    create a user + print its link(s)
  batch (NAME... | --file F) [--gb N --days N --save]   create many at once
  link NAME [--reality]         print a user's link(s)
  regen [--save --exclude a,b]  reprint links for ALL users (rollout / ECH refresh)
  list                          list usernames and status
"""
import argparse, base64, json, os, re, ssl, subprocess, sys, time
import urllib.error, urllib.parse, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CTX = ssl.create_default_context(); CTX.check_hostname = False; CTX.verify_mode = ssl.CERT_NONE
REMARK = "FINFA"


def envfile(path):
    d = {}
    try:
        with open(path) as f:
            for line in f:
                m = re.match(r"\s*([A-Z_]+)\s*=\s*'?\"?([^'\"#\n]*)", line)
                if m:
                    d[m.group(1)] = m.group(2).strip()
    except OSError:
        pass   # missing or unreadable (e.g. root-owned reality.txt) — non-fatal
    return d

ENV = envfile(os.path.join(ROOT, ".env"))
REALITY = envfile(os.path.join(ROOT, "secrets", "reality.txt"))
PORT = ENV.get("PANEL_PORT", "8000")
BASE = f"https://127.0.0.1:{PORT}"
USER = ENV.get("SUDO_USERNAME", "admin")
PASS = ENV.get("SUDO_PASSWORD", "")
DOMAIN = ENV.get("CF_DOMAIN", "")
CLEAN_IPS = [ip.strip() for ip in ENV.get("CF_CLEAN_IP", "").split(",") if ip.strip()]


def cdn_enabled():
    return bool(DOMAIN and CLEAN_IPS)


def req(method, path, token=None, data=None, form=None):
    r = urllib.request.Request(BASE + path, method=method)
    if token:
        r.add_header("Authorization", f"Bearer {token}")
    if form is not None:
        r.data = urllib.parse.urlencode(form).encode()
    elif data is not None:
        r.data = json.dumps(data).encode(); r.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(r, context=CTX, timeout=15) as resp:
        body = resp.read()
        return json.loads(body) if body else {}


def token():
    if not PASS:
        sys.exit("No SUDO_PASSWORD in .env — run setup.sh first.")
    return req("POST", "/api/admin/token", form={"username": USER, "password": PASS})["access_token"]


def ws_path():
    """Read the VLESS-WS inbound path from the Xray config."""
    cfg = json.load(open(os.path.join(ROOT, "xray", "xray_config.json")))
    for ib in cfg.get("inbounds", []):
        if ib.get("tag") == "VLESS-WS":
            return ib.get("streamSettings", {}).get("wsSettings", {}).get("path", "/")
    return "/"


def fetch_ech(domain):
    """Pull the current ECH config from the domain's DNS HTTPS record (via dig).
    Returns '' if ECH isn't published or dig is unavailable (then links omit it)."""
    try:
        out = subprocess.run(["dig", "+short", "HTTPS", domain],
                             capture_output=True, text=True, timeout=10).stdout
    except (FileNotFoundError, subprocess.SubprocessError):
        return ""
    m = re.search(r"ech=([A-Za-z0-9+/=]+)", out)
    return m.group(1) if m else ""


def user_uuid(tok, name):
    return req("GET", f"/api/user/{name}", token=tok)["proxies"]["vless"]["id"]


def cdn_links(uuid, name):
    """Build WS+TLS+ECH links pinned to each clean IP (no DNS, hidden SNI)."""
    ech = fetch_ech(DOMAIN)
    ech_q = "&ech=" + urllib.parse.quote(ech, safe="") if ech else ""
    path_q = urllib.parse.quote(ws_path(), safe="")
    links = []
    for i, ip in enumerate(CLEAN_IPS, 1):
        label = urllib.parse.quote(f"{REMARK}-{i} ({name})")
        links.append(f"vless://{uuid}@{ip}:443?security=tls&type=ws&headerType=&path={path_q}"
                     f"&host={DOMAIN}&sni={DOMAIN}&fp=chrome{ech_q}#{label}")
    return links


def sub_lines(tok, username):
    info = req("GET", f"/api/user/{username}", token=tok)
    sub = info.get("subscription_url", "").split("/sub/")[-1]
    raw = urllib.request.urlopen(urllib.request.Request(BASE + f"/sub/{sub}"),
                                 context=CTX, timeout=15).read().decode()
    try:
        raw = base64.b64decode(raw + "==").decode()
    except Exception:
        pass
    return [l for l in raw.strip().splitlines() if l.startswith("vless://")]


def user_links(tok, name):
    """Authoritative link(s) for a user: CDN (clean-IP+ECH) if enabled, else Reality."""
    if cdn_enabled():
        return cdn_links(user_uuid(tok, name), name)
    lines = sub_lines(tok, name)
    return [lines[0]] if lines else []


def ws_host_present(tok):
    return any(h.get("address") for h in req("GET", "/api/hosts", token=tok).get("VLESS-WS", []))


def ensure_user(tok, name, gb=0, days=0):
    """Create the user (idempotent) on the right inbounds; return its link(s)."""
    inbounds = ["VLESS-Reality", "VLESS-WS"] if cdn_enabled() else ["VLESS-Reality"]
    payload = {
        "username": name,
        "proxies": {"vless": {"flow": "xtls-rprx-vision"}},
        "inbounds": {"vless": inbounds},
        "data_limit": int(gb * 1024**3) if gb else 0,
        "data_limit_reset_strategy": "no_reset",
        "expire": int(time.time() + days * 86400) if days else 0,
        "status": "active",
    }
    try:
        req("POST", "/api/user", token=tok, data=payload)
    except urllib.error.HTTPError as e:
        if e.code != 409:
            sys.exit(f"create {name} failed {e.code}: {e.read().decode()}")
        # exists: make sure it's on the WS inbound too
        info = req("GET", f"/api/user/{name}", token=tok)
        req("PUT", f"/api/user/{name}", token=tok,
            data={"proxies": info["proxies"], "inbounds": {"vless": inbounds}})
    return user_links(tok, name)


def save_links(name, links):
    p = os.path.join(ROOT, "secrets", f"{name}-vless.txt")
    open(p, "w").write("\n".join(links) + "\n"); os.chmod(p, 0o600)
    return p


# ---- commands ---------------------------------------------------------------
def cmd_wait(a):
    for _ in range(60):
        try:
            urllib.request.urlopen(urllib.request.Request(BASE + "/docs"), context=CTX, timeout=3)
            print("panel up"); return
        except Exception:
            time.sleep(2)
    sys.exit("panel did not come up in time")


def cmd_set_host(a):
    sni = a.sni or REALITY.get("REALITY_SNI")
    if not (a.address and sni):
        sys.exit("need --address and an SNI (from secrets/reality.txt or --sni)")
    tok = token()
    hosts = req("GET", "/api/hosts", token=tok)
    hosts["VLESS-Reality"] = [{
        "remark": f"{REMARK}-Reality ({{USERNAME}})",
        "address": a.address, "port": 443, "sni": sni, "host": sni,
        "security": "inbound_default", "alpn": "", "fingerprint": "chrome",
        "allowinsecure": False, "is_disabled": False,
    }]
    req("PUT", "/api/hosts", token=tok, data=hosts)
    print(f"Reality host set: address={a.address} sni={sni}")


def cmd_set_ws_host(a):
    domain = a.domain or DOMAIN
    if not domain:
        sys.exit("need --domain (or CF_DOMAIN in .env)")
    # Address: a clean IP if we have one (so even Marzban's own link skips DNS).
    addr = CLEAN_IPS[0] if CLEAN_IPS else domain
    tok = token()
    hosts = req("GET", "/api/hosts", token=tok)
    hosts["VLESS-WS"] = [{
        "remark": f"{REMARK}-CDN ({{USERNAME}})",
        "address": addr, "port": 443, "sni": domain, "host": domain, "path": ws_path(),
        "security": "tls", "alpn": "", "fingerprint": "chrome",
        "allowinsecure": False, "is_disabled": False,
    }]
    req("PUT", "/api/hosts", token=tok, data=hosts)
    ech = "yes" if fetch_ech(domain) else "NO (SNI will be visible — is ECH on for the zone?)"
    print(f"CDN host set: addr={addr} sni/host={domain} path={ws_path()} | ECH published: {ech}")


def cmd_migrate_ws(a):
    tok = token()
    if not ws_host_present(tok):
        print("warning: no VLESS-WS host set yet (run set-ws-host first)")
    users = [u["username"] for u in req("GET", "/api/users", token=tok).get("users", [])]
    for u in users:
        info = req("GET", f"/api/user/{u}", token=tok)
        req("PUT", f"/api/user/{u}", token=tok,
            data={"proxies": info["proxies"], "inbounds": {"vless": ["VLESS-Reality", "VLESS-WS"]}})
    print(f"assigned {len(users)} users to the WS inbound")


def cmd_adduser(a):
    tok = token()
    links = ensure_user(tok, a.name, a.gb, a.days)
    print(f"== {a.name} ==")
    for l in links:
        print(l)
    if a.save and links:
        print("saved", save_links(a.name, links))


def cmd_batch(a):
    names = list(a.names)
    if a.file:
        names += [l.strip() for l in open(a.file) if l.strip() and not l.lstrip().startswith("#")]
    if not names:
        sys.exit("give names as args or --file")
    tok = token()
    for n in names:
        links = ensure_user(tok, n, a.gb, a.days)
        print(f"== {n} ==")
        for l in links:
            print(l)
        if a.save and links:
            save_links(n, links)
    print(f"\ndone: {len(names)} users ({', '.join(names)})")


def cmd_link(a):
    tok = token()
    if a.reality:
        lines = sub_lines(tok, a.name)
        print(next((l for l in lines if "reality" in l), lines[0] if lines else "")); return
    for l in user_links(tok, a.name):
        print(l)


def cmd_regen(a):
    tok = token()
    excl = set((a.exclude or "").split(",")) | {""}
    for u in req("GET", "/api/users", token=tok).get("users", []):
        name = u["username"]
        if name in excl:
            continue
        links = user_links(tok, name)
        print(f"== {name} ==")
        for l in links:
            print(l)
        if a.save and links:
            save_links(name, links)


def cmd_list(a):
    for u in req("GET", "/api/users", token=token()).get("users", []):
        print(f"{u['status']:9} {u['username']}")


def main():
    p = argparse.ArgumentParser(prog="marzban.py")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("wait").set_defaults(fn=cmd_wait)
    sp = sub.add_parser("set-host"); sp.add_argument("--address", required=True); sp.add_argument("--sni"); sp.set_defaults(fn=cmd_set_host)
    sp = sub.add_parser("set-ws-host"); sp.add_argument("--domain"); sp.set_defaults(fn=cmd_set_ws_host)
    sub.add_parser("migrate-ws").set_defaults(fn=cmd_migrate_ws)
    sp = sub.add_parser("adduser"); sp.add_argument("name"); sp.add_argument("--gb", type=float, default=0); sp.add_argument("--days", type=int, default=0); sp.add_argument("--save", action="store_true"); sp.set_defaults(fn=cmd_adduser)
    sp = sub.add_parser("batch"); sp.add_argument("names", nargs="*"); sp.add_argument("--file"); sp.add_argument("--gb", type=float, default=0); sp.add_argument("--days", type=int, default=0); sp.add_argument("--save", action="store_true"); sp.set_defaults(fn=cmd_batch)
    sp = sub.add_parser("link"); sp.add_argument("name"); sp.add_argument("--reality", action="store_true"); sp.set_defaults(fn=cmd_link)
    sp = sub.add_parser("regen"); sp.add_argument("--save", action="store_true"); sp.add_argument("--exclude", default="testuser"); sp.set_defaults(fn=cmd_regen)
    sub.add_parser("list").set_defaults(fn=cmd_list)
    a = p.parse_args(); a.fn(a)


if __name__ == "__main__":
    main()
