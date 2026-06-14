# Isolation verification (HARD GATE)

Do **not** create real users or hand anything off until **all three** checks
pass. They prove a VPN user egresses to the open internet and **nowhere inside
the box** (especially not the panel or anything else you run on the host).

Replace `SERVER_IP` below with your server's public IP, and `PANEL_PORT` with
your panel port (default 8000). Run checks 1–3 **from a test client connected
through the Reality tunnel** (a phone/laptop with the VPN config active).

### 1. Panel must be UNREACHABLE through the VPN
```
curl -m 5 http://127.0.0.1:PANEL_PORT/      # the CLIENT's own loopback — should just fail locally
curl -m 5 http://SERVER_IP:PANEL_PORT/      # server's public IP, panel port
```
**PASS =** both fail/refuse/time out. The routing block (`geoip:private` +
loopback → blackhole) plus the loopback-only publish guarantee this.

### 2. Host internals must be UNREACHABLE through the VPN
```
curl -m 5 http://SERVER_IP:22              # or any internal/private port you want to prove closed
nc -vz -w 3 SERVER_IP <internal-port>
```
**PASS =** no internal/private service is reachable through the VPN.

### 3. The open internet MUST work
```
curl -m 10 https://api.ipify.org    # should return the SERVER's public IP
curl -m 10 https://www.wikipedia.org -o /dev/null -w '%{http_code}\n'
```
**PASS =** normal public sites load, and the reported egress IP is the VPS's
public IP (proving traffic exits the box to the internet).

### Server-side sanity (run on the host)
```
./scripts/diagnose.sh status                # container up, :443 listening, core version, config sane
grep -A2 'geoip:private' xray/xray_config.json   # routing block present & intact
```

**If any check fails, STOP.** Re-check the routing block in
`xray/xray_config.json` and the firewall before going further.
