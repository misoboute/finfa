#!/usr/bin/env python3
"""FINFA concurrency cap (Phase 8).

Tails Xray's access log, counts distinct source IPs per user (Marzban sets the
client `email` tag to the username) over a sliding window, and when a user
exceeds WATCH_IP_LIMIT, disables them via the Marzban API for a cooldown, then
re-enables. Start in WATCH_DRY_RUN=true to observe before enforcing.

This is intentionally small and dependency-light. It is NOT a substitute for the
Xray routing isolation block — it only enforces the per-user device cap.
"""
import os
import re
import time
import logging
from collections import defaultdict, deque

import requests

LOG_PATH   = os.environ.get("WATCH_ACCESS_LOG", "/var/lib/marzban/access.log")
IP_LIMIT   = int(os.environ.get("WATCH_IP_LIMIT", "1"))
WINDOW     = int(os.environ.get("WATCH_WINDOW_SECONDS", "120"))
COOLDOWN   = int(os.environ.get("WATCH_COOLDOWN_SECONDS", "300"))
DRY_RUN    = os.environ.get("WATCH_DRY_RUN", "true").lower() in ("1", "true", "yes")
BASE_URL   = os.environ.get("MARZBAN_BASE_URL", "https://marzban:8000").rstrip("/")
ADMIN_USER = os.environ.get("MARZBAN_ADMIN_USERNAME", "admin")
ADMIN_PASS = os.environ.get("MARZBAN_ADMIN_PASSWORD", "")

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s finfa-watcher %(levelname)s %(message)s")
log = logging.getLogger("finfa")

# Marzban serves HTTPS with our private CA; its cert SAN is 127.0.0.1/localhost,
# not the compose service name "marzban", so we skip verification on this
# internal localhost-only network. Silence the resulting urllib3 warning.
import urllib3  # noqa: E402
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
VERIFY = False

# Xray access line, e.g.:
#   2024/01/01 00:00:00 from 1.2.3.4:54321 accepted tcp:host:443 [VLESS-Reality -> direct] email: alice
IP_RE    = re.compile(r"from (\d{1,3}(?:\.\d{1,3}){3})[:\]]")
EMAIL_RE = re.compile(r"email:\s*(\S+)")

# per-user deque of (timestamp, ip)
seen = defaultdict(deque)
# user -> unix ts when their disable cooldown ends
cooldown_until = {}


class Marzban:
    def __init__(self):
        self.token = None

    def _auth(self):
        r = requests.post(f"{BASE_URL}/api/admin/token",
                          data={"username": ADMIN_USER, "password": ADMIN_PASS},
                          timeout=10, verify=VERIFY)
        r.raise_for_status()
        self.token = r.json()["access_token"]

    def set_status(self, username, status):
        if DRY_RUN:
            log.warning("[DRY-RUN] would set user=%s status=%s", username, status)
            return True
        # API failures must NOT crash the watcher — log and report failure so the
        # caller can retry on the next event/tick.
        try:
            for attempt in range(2):
                if not self.token:
                    self._auth()
                h = {"Authorization": f"Bearer {self.token}"}
                r = requests.put(f"{BASE_URL}/api/user/{username}",
                                 json={"status": status}, headers=h,
                                 timeout=10, verify=VERIFY)
                if r.status_code == 401:           # token expired -> refresh once
                    self.token = None
                    continue
                r.raise_for_status()
                log.info("set user=%s status=%s", username, status)
                return True
        except Exception as e:
            log.error("API call failed (user=%s status=%s): %s", username, status, e)
        return False


def prune(user, now):
    dq = seen[user]
    while dq and now - dq[0][0] > WINDOW:
        dq.popleft()


def distinct_ips(user):
    return {ip for _, ip in seen[user]}


def follow(path):
    """Yield new lines, tolerating rotation/truncation."""
    while not os.path.exists(path):
        log.info("waiting for access log at %s ...", path)
        time.sleep(2)
    with open(path, "r", errors="ignore") as f:
        f.seek(0, os.SEEK_END)
        inode = os.fstat(f.fileno()).st_ino
        while True:
            line = f.readline()
            if line:
                yield line
                continue
            time.sleep(0.5)
            yield None          # idle heartbeat: lets main() run housekeeping
                                # (e.g. cooldown release) even with no traffic
            try:
                if os.stat(path).st_ino != inode:      # rotated
                    f.close()
                    yield from follow(path)
                    return
            except FileNotFoundError:
                pass


def main():
    mz = Marzban()
    log.info("watcher start: limit=%d window=%ds cooldown=%ds dry_run=%s log=%s",
             IP_LIMIT, WINDOW, COOLDOWN, DRY_RUN, LOG_PATH)
    for line in follow(LOG_PATH):
        now = time.time()

        # release expired cooldowns (runs on every tick, incl. idle heartbeats,
        # so users get re-enabled even though disabled users produce no traffic)
        for user, until in list(cooldown_until.items()):
            if now >= until:
                if mz.set_status(user, "active"):
                    cooldown_until.pop(user, None)
                    seen[user].clear()
                    log.info("released user=%s (cooldown elapsed)", user)
                # if re-enable failed, leave in cooldown_until to retry next tick

        if line is None:        # idle heartbeat — nothing more to do
            continue

        m_email = EMAIL_RE.search(line)
        m_ip = IP_RE.search(line)
        if not (m_email and m_ip):
            continue
        # Marzban tags the access-log email as "<id>.<username>" (e.g. "1.alice").
        # Strip the numeric id so we use the real username for the API call.
        user = re.sub(r"^\d+\.", "", m_email.group(1))
        ip = m_ip.group(1)
        if user in cooldown_until:
            continue

        dq = seen[user]
        if not dq or dq[-1][1] != ip or now - dq[-1][0] > 1:
            dq.append((now, ip))
        prune(user, now)

        ips = distinct_ips(user)
        if len(ips) > IP_LIMIT:
            log.warning("CAP TRIPPED user=%s ips=%d>%d (%s)",
                        user, len(ips), IP_LIMIT, ", ".join(sorted(ips)))
            if mz.set_status(user, "disabled"):
                cooldown_until[user] = now + COOLDOWN
            # if disable failed, don't set cooldown — retry on next matching line


if __name__ == "__main__":
    main()
