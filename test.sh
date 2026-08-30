#!/usr/bin/env bash
# Honeycode's checks.
#
# Writes nothing into build/ and never stops a running app — deliberately, so
# this is safe to run while you're using the thing it's testing. `build.sh`
# quits Honeycode to overwrite the binary it has mapped; nothing here does.
#
# There is no test framework, for the same reason there is no package manifest:
# a target is one swiftc invocation, and a second tool would be more machinery
# than the thing it tests. Each suite is a `main.swift` that prints ok/FAIL
# lines and exits non-zero, compiled against the real sources rather than a copy
# of their logic — copies are the failure mode that makes a passing suite
# worthless, and two of these exist because a copy would have agreed with a
# wrong assumption.
#
#   ./test.sh              everything
#   ./test.sh --typecheck   both targets compile, nothing runs (a fast loop)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# What to check against.
#
# The same floor `build.sh` ships, and that is the point of it being here: a
# deployment target nobody typechecks is a claim, and this is the loop that
# turns it into a fact. `--typecheck` at 15.0 is the cheapest way to find out
# whether the app still fits under it.
#
#     HONEYCODE_DEPLOY=14.0 ./test.sh --typecheck   # push it lower
#     HONEYCODE_DEPLOY=26.0 ./test.sh --typecheck   # or back to where it began
#
# Whatever swiftc accepts, it accepts — a deployment target is checked, not
# guessed at.
ARCH="${HONEYCODE_ARCH:-$(uname -m)}"
DEPLOY="${HONEYCODE_DEPLOY:-15.0}"
TARGET="$ARCH-apple-macos$DEPLOY"
WORK="$(mktemp -d)"
SERVER=""

cleanup() {
  [[ -n "$SERVER" ]] && kill "$SERVER" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# -Onone throughout: these are checks, not benchmarks, and whole-module
# optimisation on the whole of AgentKit four times over is most of the runtime.
SWIFTC=(xcrun --sdk macosx swiftc -target "$TARGET" -swift-version 5 -Onone)

# The same boundary build.sh guards, checked here too so a `--typecheck` loop
# catches it at the same moment the real build would.
echo "==> AgentKit stays free of UI frameworks"
if grep -lE '^import (SwiftUI|AppKit|WebKit|Charts|Quartz|PDFKit)$' "$ROOT"/Sources/AgentKit/*.swift 2>/dev/null | grep -q .; then
  echo "==> AgentKit must not import UI frameworks:" >&2
  grep -lE '^import (SwiftUI|AppKit|WebKit|Charts|Quartz|PDFKit)$' "$ROOT"/Sources/AgentKit/*.swift >&2
  exit 1
fi

# shellcheck disable=SC2046
echo "==> Typechecking Honeycode"
"${SWIFTC[@]}" -typecheck \
  -framework AppKit -framework SwiftUI \
  -framework Quartz \
  $(find "$ROOT/Sources/AgentKit" "$ROOT/Sources/Honeycode" -name '*.swift' | sort)

# shellcheck disable=SC2046
echo "==> Typechecking ai"
"${SWIFTC[@]}" -typecheck \
  $(find "$ROOT/Sources/AgentKit" "$ROOT/Sources/ai" -name '*.swift' | sort)

if [[ "${1:-}" == "--typecheck" ]]; then
  echo "==> Both targets compile"
  exit 0
fi

# A suite over the engine: all of AgentKit plus one file holding `main`.
kit() {
  local name="$1"
  echo "==> $name"
  # shellcheck disable=SC2046
  "${SWIFTC[@]}" -o "$WORK/$name" \
    $(find "$ROOT/Sources/AgentKit" -name '*.swift' | sort) \
    "$ROOT/Tests/$name/main.swift"
  "$WORK/$name"
}

kit Tenancy
kit Confinement
kit Turns
kit Messages
kit Seats
kit Rounds
kit Fences
kit Ledger
kit Overlap
kit Checks
kit Teams
kit Changes
kit Setup
kit Usage

# The terminal client's own logic: what Tab offers, what a slash command parses
# to, what the up-arrow remembers. Not the whole of Sources/ai — `main.swift`
# *is* a main and two of those do not link — so this names the files that hold
# the logic. Everything left out is a loop over read(2) against a tty, which
# there isn't one of in here.
echo "==> CLI"
# shellcheck disable=SC2046
"${SWIFTC[@]}" -o "$WORK/CLI" \
  $(find "$ROOT/Sources/AgentKit" -name '*.swift' | sort) \
  "$ROOT/Sources/ai/Commands.swift" \
  "$ROOT/Sources/ai/Completion.swift" \
  "$ROOT/Sources/ai/Help.swift" \
  "$ROOT/Sources/ai/History.swift" \
  "$ROOT/Tests/CLI/main.swift"
"$WORK/CLI"

# The sandbox suite drives a real WKWebView against a real local server, which
# is the only way to learn anything about a content rule list: every interesting
# property of one — whether `ignore-previous-rules` cancels a notification,
# whether a blocked document reaches the navigation delegate — is undocumented
# and had to be measured.
echo "==> Sandbox"
PORT="$(python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()')"
python3 -m http.server "$PORT" --bind 127.0.0.1 \
  --directory "$ROOT/Tests/Sandbox/site" >/dev/null 2>&1 &
SERVER=$!
# Out of job control, so killing it at the end isn't announced as a failure.
disown "$SERVER" 2>/dev/null || true
for _ in $(seq 1 40); do
  curl -sf -o /dev/null "http://127.0.0.1:$PORT/index.html" && break
  sleep 0.1
done

"${SWIFTC[@]}" -framework AppKit -framework SwiftUI -o "$WORK/Sandbox" \
  "$ROOT/Sources/Honeycode/WebPreview.swift" \
  "$ROOT/Tests/Sandbox/Stubs.swift" \
  "$ROOT/Tests/Sandbox/main.swift"
HONEYCODE_TEST_PORT="$PORT" "$WORK/Sandbox"

echo "==> All checks passed"
