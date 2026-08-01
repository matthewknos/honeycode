#!/usr/bin/env bash
# Builds Bench.app. Command Line Tools are enough; full Xcode is not required.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$ROOT/build/Honeycode.app"
TARGET="arm64-apple-macos26.0"

CONFIGURATION="${1:-release}"
case "$CONFIGURATION" in
  debug)   SWIFT_FLAGS=(-Onone -g) ;;
  release) SWIFT_FLAGS=(-O) ;;
  *) echo "usage: $0 [debug|release] [--run]" >&2; exit 2 ;;
esac

echo "==> Building Honeycode ($CONFIGURATION)"

# Quit a running copy so we can overwrite the binary it has mapped.
if pgrep -x Honeycode >/dev/null 2>&1; then
  echo "==> Stopping running Honeycode"
  pkill -x Honeycode || true
  sleep 0.4
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Vendored Highlightr looks these up with `Bundle(for:)`, which for a class
# compiled into the app is the main bundle — so they must sit flat in
# Contents/Resources, not in a subdirectory.
cp "$ROOT"/Resources/Highlight/* "$APP/Contents/Resources/"
cp "$ROOT/Resources/Icon/Honeycode.icns" "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/Flux"
cp "$ROOT/Resources/Flux/flux.html" "$APP/Contents/Resources/Flux/flux.html"

# shellcheck disable=SC2046
xcrun --sdk macosx swiftc \
  -target "$TARGET" \
  -swift-version 5 \
  "${SWIFT_FLAGS[@]}" \
  -framework AppKit -framework SwiftUI \
  -framework Speech -framework AVFoundation \
  -o "$APP/Contents/MacOS/Honeycode" \
  $(find "$ROOT/Sources" -name '*.swift' | sort)

# Signed with a stable local identity when there is one, ad-hoc otherwise.
#
# It matters for permissions, not distribution. An ad-hoc signature makes the
# app's designated requirement nothing but its own cdhash, and that changes with
# every build — so macOS treats each build as a new program and TCC asks again
# for Documents and Desktop, every time. A certificate pins the requirement to
# the identifier and the cert instead, and the grants survive a rebuild.
#
# Run tools/signing-identity.sh once to create it. Without it everything still
# builds; you just keep answering the prompts.
IDENTITY="Honeycode Local Signing"
if security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
  SIGN="$IDENTITY"
  echo "==> Signing as '$IDENTITY'"
else
  SIGN="-"
  echo "==> Signing ad-hoc (run tools/signing-identity.sh to stop the repeated"
  echo "    Documents/Desktop permission prompts)"
fi

# Hardened runtime + entitlements are not optional: without
# com.apple.security.device.audio-input the microphone is blocked with no
# prompt and no error, and dictation silently never starts.
codesign --force --sign "$SIGN" \
  --identifier com.matthewquigley.honeycode \
  --options runtime \
  --entitlements "$ROOT/Resources/Bench.entitlements" \
  "$APP"

echo "==> Built $APP"

if [[ " $* " == *" --run "* ]]; then
  open "$APP"
  echo "==> Launched $APP"
fi
