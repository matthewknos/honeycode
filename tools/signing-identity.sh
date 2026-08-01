#!/usr/bin/env bash
# Creates the local code-signing identity Honeycode is signed with.
#
# Run once. Ad-hoc signing (`codesign -s -`) gives the app a designated
# requirement of nothing but its own cdhash, and the cdhash changes with every
# build — so macOS sees each build as a different program and TCC asks again for
# Documents, Desktop and the rest. Signing with a stable certificate makes the
# requirement `identifier "com.matthewquigley.honeycode" and cert leaf = <this
# certificate>`, which survives a rebuild, so the permissions granted once stay
# granted.
#
# The certificate is self-signed and lives only in this login keychain. It says
# nothing to anyone else's Mac — Gatekeeper still treats the app as unsigned by
# an unknown developer. It exists to give the app a durable identity locally.
set -euo pipefail

NAME="Honeycode Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "==> '$NAME' already exists in the login keychain"
  security find-identity -v -p codesigning | grep -F "$NAME" || true
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Generating a self-signed code-signing certificate"
# extendedKeyUsage=codeSigning is what makes `security find-identity -p
# codesigning` list it; without it the key is present but never offered.
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -subj "/CN=$NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# A throwaway password rather than an empty one: `security import` fails the
# PKCS#12 MAC check on an empty-password bundle. The bundle is deleted on exit
# either way.
PASS="honeycode-$RANDOM"
openssl pkcs12 -export -out "$WORK/identity.p12" \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -passout "pass:$PASS" -name "$NAME"

echo "==> Importing into the login keychain"
# -A lets any program use this key without a per-signature prompt. The
# alternative (-T /usr/bin/codesign) needs the login password piped to
# `set-key-partition-list`, and this key signs nothing but this app.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -A

echo "==> Trusting it for code signing"
echo "    macOS will ask for your login password."
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo
security find-identity -v -p codesigning
echo
echo "==> Done. ./build.sh now signs with '$NAME'."
echo "    The first build after this still prompts for Documents/Desktop once;"
echo "    every build after that inherits the same grant."
