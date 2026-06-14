#!/usr/bin/env python3
"""FINFA Marzban ops CLI — stdlib only (runs on a bare Ubuntu with python3).

Talks to the local Marzban panel over its loopback HTTPS port. Reads the admin
password from .env and the Reality public values from secrets/reality.txt.

Subcommands:
  wait                      block until the panel answers (used by setup.sh)
  set-host --address IP     configure the VLESS-Reality Host so client links
                            carry the right IP + SNI
  adduser NAME [--gb N] [--days N] [--save]
                            create a user (default: unlimited, no expiry) and
                            print its vless:// link; --save writes secrets/<name>-vless.txt
  link NAME                 print a user's canonical vless:// link
  list                      list usernames and status
"""
import argparse, base64, json, os, re, ssl, sys, time, urllib.parse, urllib.request

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


def canonical_link(tok, username):
    """Fetch the share link from the subscription endpoint (correct sid)."""
    info = req("GET", f"/api/user/{username}", token=tok)
    sub = info.get("subscription_url", "")
    sub_token = sub.split("/sub/")[-1]
    raw = urllib.request.urlopen(urllib.request.Request(BASE + f"/sub/{sub_token}"),
                                 context=CTX, timeout=15).read().decode()
    try:
        raw = base64.b64decode(raw + "==").decode()
    except Exception:
        pass
    return raw.strip().splitlines()[0] if raw.strip() else ""


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
    host = {
        "remark": "FINFA-Reality ({USERNAME})",
        "address": a.address, "port": 443,
        "sni": sni, "host": sni,
        "security": "inbound_default", "alpn": "", "fingerprint": "chrome",
        "allowinsecure": False, "is_disabled": False,
    }
    req("PUT", "/api/hosts", token=tok, data={"VLESS-Reality": [host]})
    print(f"host set: address={a.address} sni={sni}")


def cmd_adduser(a):
    tok = token()
    payload = {
        "username": a.name,
        "proxies": {"vless": {"flow": "xtls-rprx-vision"}},
        "inbounds": {"vless": ["VLESS-Reality"]},
        "data_limit": int(a.gb * 1024**3) if a.gb else 0,
        "data_limit_reset_strategy": "no_reset",
        "expire": int(time.time() + a.days * 86400) if a.days else 0,
        "status": "active",
    }
    try:
        req("POST", "/api/user", token=tok, data=payload)
        print(f"created {a.name}")
    except urllib.error.HTTPError as e:
        if e.code == 409:
            print(f"{a.name} already exists; fetching link")
        else:
            sys.exit(f"create failed {e.code}: {e.read().decode()}")
    link = canonical_link(tok, a.name)
    print(link)
    if a.save:
        p = os.path.join(ROOT, "secrets", f"{a.name}-vless.txt")
        open(p, "w").write(link + "\n"); os.chmod(p, 0o600)
        print(f"saved {p}")


def cmd_link(a):
    print(canonical_link(token(), a.name))


def cmd_list(a):
    for u in req("GET", "/api/users", token=token()).get("users", []):
        print(f"{u['status']:9} {u['username']}")


def main():
    p = argparse.ArgumentParser(prog="marzban.py")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("wait").set_defaults(fn=cmd_wait)
    sp = sub.add_parser("set-host"); sp.add_argument("--address", required=True); sp.add_argument("--sni"); sp.set_defaults(fn=cmd_set_host)
    sp = sub.add_parser("adduser"); sp.add_argument("name"); sp.add_argument("--gb", type=float, default=0); sp.add_argument("--days", type=int, default=0); sp.add_argument("--save", action="store_true"); sp.set_defaults(fn=cmd_adduser)
    sp = sub.add_parser("link"); sp.add_argument("name"); sp.set_defaults(fn=cmd_link)
    sub.add_parser("list").set_defaults(fn=cmd_list)
    a = p.parse_args(); a.fn(a)


if __name__ == "__main__":
    main()
