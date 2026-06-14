#!/usr/bin/env bash
# Phase 0 — READ ONLY recon. Makes no changes. Run again any time to re-inventory.
set -uo pipefail
line(){ printf '\n===== %s =====\n' "$1"; }

line "OS / KERNEL";        cat /etc/os-release 2>/dev/null | head -8; echo; uname -a
line "CPU / RAM / DISK";   echo "vCPU: $(nproc)"; free -h; df -h / 2>/dev/null
line "INTERFACES / IP";    ip -br a 2>/dev/null || ip addr
line "LISTENING SOCKETS";  ss -tulpn 2>/dev/null || ss -tuln
line "  ^ flag anything bound to 0.0.0.0 (vs 127.0.0.1) — those are exposure risks"
line "DOCKER";             docker version 2>/dev/null | head -12 || echo "docker: not installed"
                          docker compose version 2>/dev/null || echo "compose plugin: not installed"
line "FIREWALL (nft)";     nft list ruleset 2>/dev/null || echo "nft: empty / no permission"
line "FIREWALL (ufw)";     ufw status 2>/dev/null || echo "ufw: not installed"
line "TRADING PROC GUESS"; ps -eo pid,user,comm,args --sort=-%cpu 2>/dev/null \
                            | grep -iE 'trad|strat|bot|ccxt|freqtrade|main.py|record' \
                            | grep -v grep | head -10 || echo "none matched (confirm with human)"
line "TOP CPU";            ps -eo pid,user,%cpu,%mem,comm --sort=-%cpu 2>/dev/null | head -8
echo
echo "Reminder: do NOT guess which listeners are trading — confirm with the box owner."
