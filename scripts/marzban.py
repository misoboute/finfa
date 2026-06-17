#!/usr/bin/env python3
"""FINFA Marzban ops CLI — stdlib only (runs on a bare Ubuntu with python3).

Talks to the local Marzban panel over its loopback HTTPS port. Reads the admin
password from .env and the Reality public values from secrets/reality.txt.

Subcommands:
  wait                      block until the panel answers (used by setup.sh)
  set-host --address IP     configure the VLESS-Reality Host so client links
                            carry the right IP + SNI
  set-ws-host --domain D    configure the VLESS-WS (Cloudflare CDN) Host so its
                            links point at your domain (path read from config)
  migrate-ws                assign ALL users to the WS inbound too (used when
                            enabling the CDN front; UUIDs preserved)
  adduser NAME [--gb N] [--days N] [--save]
                            create a user (default: unlimited, no expiry) and
                            print its vless:// link; --save writes secrets/<name>-vless.txt
                            (if the CDN host is set, the user is put on both
                            inbounds and the CDN link is printed)
  link NAME [--ws|--reality]   print a user's vless:// link
  list                      list usernames and status
"""
import argparse, base64, json, os, re, ssl, sys, time, urllib.error, urllib.parse, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CTX = ssl.create_default_context(); CTX.check_hostname = False; CTX.verify_mode = ssl.CERT_NONE


def envfile(path):
    d = {}
    if os.path.exists(path):
        for line in open(path):
            m = re.match(r"\s*([A-Z_]+)\s*=\s*'?\"?([^'\"#\n]*)", line)
            if m:
                d[m.group(1)] = m.group(2).strip()
    return d

ENV = envfile(os.path.join(ROOT, ".env"))
REALITY = envfile(os.path.join(ROOT, "secrets", "reality.txt"))
PORT = ENV.get("PANEL_PORT", "8000")
BASE = f"https://127.0.0.1:{PORT}"
USER = ENV.get("SUDO_USERNAME", "admin")
PASS = ENV.get("SUDO_PASSWORD", "")


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


def config_ws_path():
    """Read the VLESS-WS inbound path from the Xray config (set by 02-gen-reality-keys.sh)."""
    cfg = json.load(open(os.path.join(ROOT, "xray", "xray_config.json")))
    for ib in cfg.get("inbounds", []):
        if ib.get("tag") == "VLESS-WS":
            return ib.get("streamSettings", {}).get("wsSettings", {}).get("path", "/")
    return "/"


def ws_host_present(tok):
    hosts = req("GET", "/api/hosts", token=tok)
    return any(h.get("address") for h in hosts.get("VLESS-WS", []))


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


def pick_link(lines, prefer=None):
    if prefer == "ws":
        for l in lines:
            if "type=ws" in l:
                return l
    if prefer == "reality":
        for l in lines:
            if "security=reality" in l:
                return l
    return lines[0] if lines else ""


def assign(tok, username, inbounds):
    """Update a user's inbound assignment, preserving its proxies (UUID/flow)."""
    info = req("GET", f"/api/user/{username}", token=tok)
    req("PUT", f"/api/user/{username}", token=tok,
        data={"proxies": info["proxies"], "inbounds": {"vless": inbounds}})


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
        "remark": "FINFA-Reality ({USERNAME})",
        "address": a.address, "port": 443, "sni": sni, "host": sni,
        "security": "inbound_default", "alpn": "", "fingerprint": "chrome",
        "allowinsecure": False, "is_disabled": False,
    }]
    req("PUT", "/api/hosts", token=tok, data=hosts)
    print(f"Reality host set: address={a.address} sni={sni}")


def cmd_set_ws_host(a):
    domain = a.domain or ENV.get("CF_DOMAIN")
    if not domain:
        sys.exit("need --domain (or CF_DOMAIN in .env)")
    path = config_ws_path()
    tok = token()
    hosts = req("GET", "/api/hosts", token=tok)
    hosts["VLESS-WS"] = [{
        "remark": "FINFA-CDN ({USERNAME})",
        "address": domain, "port": 443, "sni": domain, "host": domain, "path": path,
        "security": "tls", "alpn": "", "fingerprint": "chrome",
        "allowinsecure": False, "is_disabled": False,
    }]
    req("PUT", "/api/hosts", token=tok, data=hosts)
    print(f"CDN (WS) host set: domain={domain} path={path}")


def cmd_migrate_ws(a):
    tok = token()
    if not ws_host_present(tok):
        print("warning: no VLESS-WS host set yet (run set-ws-host first)")
    users = [u["username"] for u in req("GET", "/api/users", token=tok).get("users", [])]
    for u in users:
        assign(tok, u, ["VLESS-Reality", "VLESS-WS"])
    print(f"assigned {len(users)} users to the WS inbound: {', '.join(users)}")


def cmd_adduser(a):
    tok = token()
    cdn = ws_host_present(tok)
    inbounds = ["VLESS-Reality", "VLESS-WS"] if cdn else ["VLESS-Reality"]
    payload = {
        "username": a.name,
        "proxies": {"vless": {"flow": "xtls-rprx-vision"}},
        "inbounds": {"vless": inbounds},
        "data_limit": int(a.gb * 1024**3) if a.gb else 0,
        "data_limit_reset_strategy": "no_reset",
        "expire": int(time.time() + a.days * 86400) if a.days else 0,
        "status": "active",
    }
    try:
        req("POST", "/api/user", token=tok, data=payload)
        print(f"created {a.name}" + (" (Reality + CDN)" if cdn else ""))
    except urllib.error.HTTPError as e:
        if e.code == 409:
            print(f"{a.name} already exists; fetching link")
            if cdn:
                assign(tok, a.name, inbounds)
        else:
            sys.exit(f"create failed {e.code}: {e.read().decode()}")
    link = pick_link(sub_lines(tok, a.name), prefer="ws" if cdn else None)
    print(link)
    if a.save:
        p = os.path.join(ROOT, "secrets", f"{a.name}-vless.txt")
        open(p, "w").write(link + "\n"); os.chmod(p, 0o600)
        print(f"saved {p}")


def cmd_link(a):
    prefer = "ws" if a.ws else ("reality" if a.reality else None)
    print(pick_link(sub_lines(token(), a.name), prefer=prefer))


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
    sp = sub.add_parser("link"); sp.add_argument("name"); sp.add_argument("--ws", action="store_true"); sp.add_argument("--reality", action="store_true"); sp.set_defaults(fn=cmd_link)
    sub.add_parser("list").set_defaults(fn=cmd_list)
    a = p.parse_args(); a.fn(a)


if __name__ == "__main__":
    main()
