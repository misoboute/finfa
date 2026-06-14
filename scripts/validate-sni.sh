#!/usr/bin/env bash
# Validate a candidate Reality camouflage SNI: it must support TLS 1.3 and serve
# an HTTP/2 site. Pick a real, popular HTTPS site that is itself NOT blocked
# where your users are, and is not your own brand. You choose; this sanity-checks.
#
# Usage:  ./scripts/validate-sni.sh www.example.com
set -uo pipefail
H="${1:?Usage: validate-sni.sh <domain>}"

echo "== TLS 1.3 check for $H =="
if echo | openssl s_client -connect "$H:443" -servername "$H" -tls1_3 2>/dev/null \
     | grep -q "TLSv1.3"; then
  echo "  OK: $H negotiates TLS 1.3"
else
  echo "  FAIL: $H did not negotiate TLS 1.3 — not suitable for Reality"
fi

echo "== HTTP/2 (ALPN h2) check =="
if echo | openssl s_client -connect "$H:443" -servername "$H" -alpn h2 2>/dev/null \
     | grep -q "ALPN protocol: h2"; then
  echo "  OK: $H advertises HTTP/2 (h2) — good camouflage target"
else
  echo "  NOTE: no h2 ALPN; many Reality setups still work, but h2 is preferred"
fi

echo
echo "Also confirm (manually) the site is reachable from your users' region and is popular/"
echo "innocuous. Good general candidates support TLS1.3 + h2 and are widely used."
