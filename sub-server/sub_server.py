#!/usr/bin/env python3
"""
FINFA subscription server — serves fresh VLESS+CDN links on every request.

GET /sub/<marzban_sub_token>
  Decodes the Marzban token → username → UUID from Marzban API → fresh ECH
  key from Cloudflare DoH at pinned IP 1.1.1.1 (bypasses poisoned DNS) →
  returns a base64-encoded subscription with current links.

Clients auto-update by polling this URL (recommended: every 12h, via proxy).
The ECH key in every response is live — links never go stale.
"""
import base64, http.server, json, os, re, ssl, struct, sys, urllib.parse, urllib.request

ROOT = os.environ.get("FINFA_ROOT", "/app")
MARZBAN_HOST = os.environ.get("MARZBAN_HOST", "marzban")


def _get(key, default=""):
    v = os.environ.get(key)
    if v is not None:
        return v
    try:
        with open(os.path.join(ROOT, ".env")) as f:
            for line in f:
                m = re.match(r"\s*([A-Z_]+)\s*=\s*'?\"?([^'\"#\n]*)", line)
                if m and m.group(1) == key:
                    return m.group(2).strip()
    except OSError:
        pass
    return default

PANEL_PORT = _get("PANEL_PORT", "8000")
PANEL_BASE = f"https://{MARZBAN_HOST}:{PANEL_PORT}"
ADMIN_USER = _get("SUDO_USERNAME", "admin")
ADMIN_PASS = _get("SUDO_PASSWORD", "")
DOMAIN = _get("CF_DOMAIN", "")
CLEAN_IPS = [ip.strip() for ip in _get("CF_CLEAN_IP", "").split(",") if ip.strip()]
REMARK = "FINFA"

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE


def marzban_token():
    r = urllib.request.Request(PANEL_BASE + "/api/admin/token")
    r.data = urllib.parse.urlencode({"username": ADMIN_USER, "password": ADMIN_PASS}).encode()
    with urllib.request.urlopen(r, context=CTX, timeout=10) as resp:
        return json.loads(resp.read())["access_token"]


def get_user(tok, name):
    r = urllib.request.Request(PANEL_BASE + f"/api/user/{name}")
    r.add_header("Authorization", f"Bearer {tok}")
    with urllib.request.urlopen(r, context=CTX, timeout=10) as resp:
        return json.loads(resp.read())


def fetch_ech():
    """Fetch current ECH key via DoH at pinned 1.1.1.1 (bypasses poisoned DNS).
    Parses RFC 3597 binary HTTPS record to extract SvcParam key 5 (ECH)."""
    url = f"https://1.1.1.1/dns-query?name={urllib.parse.quote(DOMAIN)}&type=HTTPS"
    r = urllib.request.Request(url)
    r.add_header("Accept", "application/dns-json")
    r.add_header("Host", "cloudflare-dns.com")
    try:
        with urllib.request.urlopen(r, timeout=8) as resp:
            for ans in json.loads(resp.read()).get("Answer", []):
                if ans.get("type") != 65:
                    continue
                data = ans.get("data", "")
                # Text format: "1 . alpn=h2 ech=AEX..." (some resolvers)
                m = re.search(r"ech=([A-Za-z0-9+/=]+)", data)
                if m:
                    return m.group(1)
                # RFC 3597 binary format: "\# <len> <hex bytes>"
                parts = data.split()
                if len(parts) >= 3 and parts[0] == r"\#":
                    raw = bytes.fromhex("".join(parts[2:]))
                    pos = 3  # skip 2-byte priority + 1-byte root target
                    while pos + 4 <= len(raw):
                        key = struct.unpack_from(">H", raw, pos)[0]; pos += 2
                        vlen = struct.unpack_from(">H", raw, pos)[0]; pos += 2
                        if key == 5:  # ECH SvcParam
                            return base64.b64encode(raw[pos:pos + vlen]).decode()
                        pos += vlen
    except Exception:
        pass
    return ""


def cdn_path():
    try:
        cfg = json.load(open(os.path.join(ROOT, "xray_config.json")))
        for ib in cfg.get("inbounds", []):
            if ib.get("tag") == "VLESS-WS":
                ss = ib.get("streamSettings", {})
                return (ss.get("xhttpSettings") or ss.get("wsSettings") or {}).get("path", "/")
    except Exception:
        pass
    return "/cdn/live"


def cdn_transport():
    try:
        cfg = json.load(open(os.path.join(ROOT, "xray_config.json")))
        for ib in cfg.get("inbounds", []):
            if ib.get("tag") == "VLESS-WS":
                return ib.get("streamSettings", {}).get("network", "ws")
    except Exception:
        pass
    return "ws"


def build_links(uuid, name, ech):
    ech_q = "&ech=" + urllib.parse.quote(ech, safe="") if ech else ""
    path_q = urllib.parse.quote(cdn_path(), safe="")
    transport = cdn_transport()
    links = []
    for i, ip in enumerate(CLEAN_IPS, 1):
        label = urllib.parse.quote(f"{REMARK}-{i} ({name})")
        links.append(
            f"vless://{uuid}@{ip}:443?security=tls&type={transport}&path={path_q}"
            f"&host={DOMAIN}&sni={DOMAIN}&fp=chrome&alpn=http%2F1.1{ech_q}#{label}"
        )
    return links


def decode_token(token):
    """Extract username from Marzban sub token (url-safe base64 of 'username,timestamp...')."""
    try:
        padded = token + "=" * (-len(token) % 4)
        raw = base64.urlsafe_b64decode(padded).decode("utf-8", errors="replace")
        username = raw.split(",")[0].strip()
        if re.match(r"^[a-zA-Z0-9_\-]{1,64}$", username):
            return username
    except Exception:
        pass
    return None


class SubHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        path = self.path.split("?")[0]
        m = re.match(r"^/sub/(.+)$", path)
        if not m:
            self.send_error(404)
            return

        username = decode_token(m.group(1))
        if not username:
            self.send_error(400, "Invalid token")
            return

        try:
            tok = marzban_token()
            user = get_user(tok, username)
            uuid = user["proxies"]["vless"]["id"]
            ech = fetch_ech()
            links = build_links(uuid, username, ech)
            body = base64.b64encode("\n".join(links).encode()).decode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body.encode())
        except Exception as e:
            self.send_error(500, str(e))


if __name__ == "__main__":
    if not (DOMAIN and CLEAN_IPS and ADMIN_PASS):
        sys.exit("CDN not configured — set CF_DOMAIN, CF_CLEAN_IP, SUDO_PASSWORD in .env")
    srv = http.server.HTTPServer(("0.0.0.0", 8090), SubHandler)
    print(f"sub-server listening on :8090  domain={DOMAIN}", flush=True)
    srv.serve_forever()
