#!/usr/bin/env bash
# Builds `ai`, the terminal client. Same engine as the app, no UI frameworks.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$ROOT/build/ai"

# What to build for.
#
# Both of these were a string literal — `arm64-apple-macos26.0` — and neither
# was a requirement anybody measured. The architecture was the machine this was
# written on, and on any other one it produces a binary that cannot execute and
# no hint as to why. The deployment target is the version it happened to be
# built against: there is not a single `@available` in the source, so nothing
# in it has ever declared needing 26.
#
# So both follow this Mac, and both can be overridden. Lowering the floor is
# the experiment:
#
#     HONEYCODE_DEPLOY=14.0 ./build.sh
#
# and read what the compiler rejects. Whatever it accepts, it accepts — a
# deployment target is checked, not guessed at.
ARCH="${HONEYCODE_ARCH:-$(uname -m)}"
DEPLOY="${HONEYCODE_DEPLOY:-26.0}"
TARGET="$ARCH-apple-macos$DEPLOY"

CONFIGURATION="${1:-release}"
case "$CONFIGURATION" in
  debug)   SWIFT_FLAGS=(-Onone -g) ;;
  release) SWIFT_FLAGS=(-O -wmo) ;;
  *) echo "usage: $0 [debug|release]" >&2; exit 2 ;;
esac

echo "==> Building ai ($CONFIGURATION)"
mkdir -p "$ROOT/build"

# AgentKit + the CLI, and deliberately not Sources/Honeycode. If this ever needs
# a UI framework to link, something has crossed the line build.sh guards.
# shellcheck disable=SC2046
xcrun --sdk macosx swiftc \
  -target "$TARGET" \
  -swift-version 5 \
  "${SWIFT_FLAGS[@]}" \
  -o "$OUT" \
  $(find "$ROOT/Sources/AgentKit" "$ROOT/Sources/ai" -name '*.swift' | sort)

echo "==> Built $OUT"
