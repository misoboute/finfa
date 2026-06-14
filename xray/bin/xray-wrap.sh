#!/bin/sh
# Shim so the OLD Marzban panel (24.x) can drive a NEW Xray core (26.x).
#
# Why: the image bundles Xray 24.12.31, which cannot parse the post-quantum
# X25519MLKEM768 TLS key share newer clients send -> every updated client
# failed Reality auth. We override the core with a current build, but Marzban
# parses `xray x25519` output to build share links, and the new core renamed
# the labels (Private key/Public key -> PrivateKey/Password (PublicKey)),
# which crashes Marzban's parser. This shim restores the old labels for the
# x25519 subcommand only; every other invocation (run, version, ...) is
# exec'd straight through to the real new binary.
REAL=/usr/local/bin/xray.real

if [ "$1" = "x25519" ]; then
    out=$("$REAL" "$@" 2>/dev/null)
    priv=$(printf '%s\n' "$out" | sed -n 's/^PrivateKey: //p')
    pub=$(printf  '%s\n' "$out" | sed -n 's/^Password (PublicKey): //p')
    printf 'Private key: %s\nPublic key: %s\n' "$priv" "$pub"
    exit 0
fi

exec "$REAL" "$@"
