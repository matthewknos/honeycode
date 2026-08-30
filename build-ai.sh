#!/usr/bin/env bash
# Builds `ai`, the terminal client. Same engine as the app, no UI frameworks.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$ROOT/build/ai"

# What to build for.
#
# **The floor is a claim the compiler checks on every build.** 26.0 was never a
# requirement — it was the version this happened to be built against, and it
# stamped `LSMinimumSystemVersion 26.0` into the bundle, so a build that would
# have run fine on an older Mac refused to open on one. `tools/availability.py`
# put the real floor at macOS 15: five call sites are behind `#available`, and
# the two that aren't — `ScrollPosition` and `onScrollGeometryChange` in the
# transcript — are macOS 15 API doing something the transcript's own comments
# record three failed attempts at doing another way.
#
# So 15.0 is the default and swiftc is the authority. If it rejects something,
# the escape hatch is one variable and the rejection names the symbol:
#
#     HONEYCODE_DEPLOY=26.0 ./build.sh    # back to where this started
#     HONEYCODE_DEPLOY=14.0 ./build.sh    # or push it lower and read the errors
#
# Architecture follows this Mac unless you ask for both. A build on Apple
# silicon produces an arm64-only app, which on an Intel Mac is not a slow app
# but a refusal to launch — so anything anybody else is going to run wants
# `--universal`, and a build you are about to use yourself does not want to pay
# twice for a slice it will never execute.
ARCH="${HONEYCODE_ARCH:-$(uname -m)}"
DEPLOY="${HONEYCODE_DEPLOY:-15.0}"

CONFIGURATION=release
UNIVERSAL=false
for argument in "$@"; do
  case "$argument" in
    debug|release) CONFIGURATION="$argument" ;;
    --universal)   UNIVERSAL=true ;;
    *) echo "usage: $0 [debug|release] [--universal]" >&2; exit 2 ;;
  esac
done

if [[ "$UNIVERSAL" == true ]]; then
  ARCHES=(arm64 x86_64)
else
  ARCHES=("$ARCH")
fi

case "$CONFIGURATION" in
  debug)   SWIFT_FLAGS=(-Onone -g) ;;
  release) SWIFT_FLAGS=(-O -wmo) ;;
esac

echo "==> Building ai ($CONFIGURATION, ${ARCHES[*]}, macOS $DEPLOY)"
mkdir -p "$ROOT/build"

# AgentKit + the CLI, and deliberately not Sources/Honeycode. If this ever needs
# a UI framework to link, something has crossed the line build.sh guards.
SOURCES=$(find "$ROOT/Sources/AgentKit" "$ROOT/Sources/ai" -name '*.swift' | sort)
SLICES=()
for slice in "${ARCHES[@]}"; do
  echo "==> Compiling $slice-apple-macos$DEPLOY"
  # shellcheck disable=SC2046
  xcrun --sdk macosx swiftc \
    -target "$slice-apple-macos$DEPLOY" \
    -swift-version 5 \
    "${SWIFT_FLAGS[@]}" \
    -o "$OUT.$slice" \
    $SOURCES
  SLICES+=("$OUT.$slice")
done

if [[ "${#SLICES[@]}" -gt 1 ]]; then
  xcrun lipo -create "${SLICES[@]}" -output "$OUT"
  rm -f "${SLICES[@]}"
  echo "==> Universal: $(xcrun lipo -archs "$OUT")"
else
  mv "${SLICES[0]}" "$OUT"
fi

echo "==> Built $OUT"
