#!/bin/sh
# Ensure the Xray access log exists and is readable before starting the watcher.
# Xray creates it as root:root 600; we open it up to group+others read-only.
LOG="${WATCH_ACCESS_LOG:-/var/lib/marzban/access.log}"
touch "$LOG" 2>/dev/null || true
chmod 644 "$LOG" 2>/dev/null || true
exec python -u /app/watcher.py
