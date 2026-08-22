#!/usr/bin/env bash
# Builds Honeycode.app. Command Line Tools are enough; full Xcode is not required.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$ROOT/build/Honeycode.app"
INSTALLED="/Applications/Honeycode.app"
TARGET="arm64-apple-macos26.0"

CONFIGURATION=release
INSTALL=false
RUN=false
for argument in "$@"; do
  case "$argument" in
    debug|release) CONFIGURATION="$argument" ;;
    --install)     INSTALL=true ;;
    --run)         RUN=true ;;
    *) echo "usage: $0 [debug|release] [--install] [--run]" >&2; exit 2 ;;
  esac
done

case "$CONFIGURATION" in
  debug)   SWIFT_FLAGS=(-Onone -g) ;;
  # Whole-module optimisation, not just -O. Every source file is handed to one
  # swiftc invocation already, so this costs nothing but lets the optimiser
  # inline and specialise across files — which for an app whose hot paths span
  # Models, the adapters and the views is most of them.
  release) SWIFT_FLAGS=(-O -wmo) ;;
esac

echo "==> Building Honeycode ($CONFIGURATION)"

# AgentKit is the half that has to run without a UI, because honeycoded links it
# and a daemon has no windows. Nothing in the language enforces that — SwiftUI
# imports perfectly well into a background process and simply drags AppKit in
# behind it — so the boundary is checked here instead. It failed exactly once,
# in the direction you would expect: a `Color` on `Account`.
if grep -lE '^import (SwiftUI|AppKit|WebKit|Charts|Quartz)$' "$ROOT"/Sources/AgentKit/*.swift 2>/dev/null | grep -q .; then
  echo "==> AgentKit must not import UI frameworks:" >&2
  grep -lE '^import (SwiftUI|AppKit|WebKit|Charts|Quartz)$' "$ROOT"/Sources/AgentKit/*.swift >&2
  exit 1
fi

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
  -framework Quartz \
  -o "$APP/Contents/MacOS/Honeycode" \
  $(find "$ROOT/Sources/AgentKit" "$ROOT/Sources/Honeycode" -name '*.swift' | sort)

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
  --entitlements "$ROOT/Resources/Honeycode.entitlements" \
  "$APP"

echo "==> Built $APP"

# Installing to /Applications, and staying installed.
#
# Nothing in the bundle knows where it lives. Resources come out of
# `Bundle.main`, preferences are keyed on the bundle identifier, and every
# session, transcript and setting is in Application Support or your home
# directory — so the .app moves anywhere and keeps working, and its signature
# covers its contents rather than its path.
#
# What doesn't survive the move is your attention. Once a copy is in
# /Applications that is the one the Dock, Spotlight and `open -a` launch, and a
# plain ./build.sh that rewrote only build/ would leave you staring at a binary
# nobody runs, wondering why the fix didn't take. So an existing install is
# refreshed on every build whether or not you passed the flag, and says so.
if [[ "$INSTALL" == true || -d "$INSTALLED" ]]; then
  if [[ ! -w /Applications ]] || { [[ -e "$INSTALLED" ]] && [[ ! -w "$INSTALLED" ]]; }; then
    echo "==> Can't write $INSTALLED as $(id -un). Either fix the owner, or:" >&2
    echo "    sudo rm -rf \"$INSTALLED\" && sudo ditto \"$APP\" \"$INSTALLED\"" >&2
    exit 1
  fi

  # ditto rather than cp -R, because it is what Apple documents for signed
  # bundles and it carries the extended attributes the signature is checked
  # against. It merges into an existing directory instead of replacing it,
  # which is why the rm is not optional — without it a file deleted from the
  # app three builds ago is still sitting in /Applications.
  rm -rf "$INSTALLED"
  ditto "$APP" "$INSTALLED"

  # A move can't invalidate a signature but a bad copy can, and that failure
  # arrives later as a launch that dies with no window and no message.
  codesign --verify --strict "$INSTALLED"

  echo "==> Installed $INSTALLED"
  APP="$INSTALLED"
fi

if [[ "$RUN" == true ]]; then
  open "$APP"
  echo "==> Launched $APP"
fi
