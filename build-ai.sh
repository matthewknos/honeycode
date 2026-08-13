#!/usr/bin/env bash
# Builds `ai`, the terminal client. Same engine as the app, no UI frameworks.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$ROOT/build/ai"

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
  -target arm64-apple-macos26.0 \
  -swift-version 5 \
  "${SWIFT_FLAGS[@]}" \
  -o "$OUT" \
  $(find "$ROOT/Sources/AgentKit" "$ROOT/Sources/ai" -name '*.swift' | sort)

echo "==> Built $OUT"
