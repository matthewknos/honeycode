#!/usr/bin/env bash
# What Honeycode needs, and whether this machine has it.
#
# Run before the first build. Nothing here changes anything — it looks, reports,
# and tells you the one command that fixes what it found. Exits non-zero only
# when something is missing that stops the app building or launching at all;
# a missing agent CLI is a warning, because three of the four accounts are
# optional and the app is useful with one.
#
# The checks are deliberately the same ones the app makes at runtime, in the
# same order and against the same paths — see `ACPAgent.binaryCandidates` and
# `Account.claudeDirectory`. A doctor that looks somewhere else than the program
# is a doctor that clears a machine the program then fails on.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Colour only when a terminal is watching, so piping this into a file or a CI
# log doesn't fill it with escape codes.
if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
  YELLOW=$'\033[33m'; RESET=$'\033[0m'
else
  BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; RESET=""
fi

FATAL=0
WARNED=0

heading() { printf '\n%s%s%s\n' "$BOLD" "$1" "$RESET"; }
ok()      { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; }
note()    { printf '    %s%s%s\n' "$DIM" "$1" "$RESET"; }
warn()    { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$1"; WARNED=$((WARNED + 1)); }
fail()    { printf '  %s✗%s %s\n' "$RED" "$RESET" "$1"; FATAL=$((FATAL + 1)); }

# The same list `ACPAgent.binaryCandidates` walks, and in the same order. A tool
# on your shell's PATH but in none of these is found by you and not by the app,
# which is the single most confusing way for this to go wrong: it works in the
# terminal and the app says it can't find it.
find_tool() {
  local tool="$1" path
  for path in "$HOME/.local/bin/$tool" /opt/homebrew/bin/"$tool" /usr/local/bin/"$tool"; do
    [[ -x "$path" ]] && { echo "$path"; return 0; }
  done
  # nvm installs per Node version, newest first.
  local nvm="$HOME/.nvm/versions/node"
  if [[ -d "$nvm" ]]; then
    local version
    while IFS= read -r version; do
      [[ -x "$nvm/$version/bin/$tool" ]] && { echo "$nvm/$version/bin/$tool"; return 0; }
    done < <(ls "$nvm" 2>/dev/null | sort -rV)
  fi
  return 1
}

# Found by the shell but not where the app looks — worth saying out loud.
elsewhere() {
  local tool="$1" found
  found="$(command -v "$tool" 2>/dev/null)" || return 1
  echo "$found"
}

printf '%sHoneycode — checking this machine%s\n' "$BOLD" "$RESET"

# ---------------------------------------------------------------- the machine

heading "macOS"

ARCH="$(uname -m)"
if [[ "$ARCH" == "arm64" ]]; then
  ok "Apple silicon ($ARCH)"
else
  fail "Apple silicon required — this is $ARCH"
  note "Both build scripts target arm64-apple-macos26.0. On an Intel Mac you"
  note "would need to change TARGET in build.sh and build-ai.sh, and nothing"
  note "here has been tested that way."
fi

VERSION="$(sw_vers -productVersion)"
MAJOR="${VERSION%%.*}"
if (( MAJOR >= 26 )); then
  ok "macOS $VERSION"
else
  fail "macOS 26 or later required — this is $VERSION"
  note "LSMinimumSystemVersion in Resources/Info.plist, and the deployment"
  note "target both build scripts compile against."
fi

# ------------------------------------------------------------- the toolchain

heading "Toolchain"

if xcrun --sdk macosx --find swiftc >/dev/null 2>&1; then
  SWIFT="$(xcrun --sdk macosx swiftc --version 2>/dev/null | head -1)"
  ok "swiftc — ${SWIFT:-found}"
else
  fail "swiftc not found"
  note "xcode-select --install"
  note "Command Line Tools are enough; full Xcode is not required."
fi

if xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; then
  ok "macOS SDK — $(xcrun --sdk macosx --show-sdk-version 2>/dev/null)"
else
  fail "no macOS SDK"
  note "sudo xcode-select --switch /Library/Developer/CommandLineTools"
fi

if command -v python3 >/dev/null 2>&1; then
  ok "python3 — serves the local site the Sandbox suite drives a WKWebView at"
else
  warn "python3 not found — ./test.sh will fail at the Sandbox suite"
  note "Everything else, including both builds, works without it."
fi

# ----------------------------------------------------------------- accounts

heading "Claude accounts"

# Claude is the only account with two seats out of the box, and the only one
# switched by configuration rather than by a separate login: CLAUDE_CONFIG_DIR
# is the whole of it. Both default to a directory this script can check.
CLAUDE="$(find_tool claude || true)"
if [[ -n "$CLAUDE" ]]; then
  ok "claude — $CLAUDE"
else
  ALSO="$(elsewhere claude || true)"
  if [[ -n "$ALSO" ]]; then
    warn "claude is at $ALSO, which is not where Honeycode looks"
    note "It searches ~/.local/bin, /opt/homebrew/bin, /usr/local/bin and the"
    note "nvm tree — an app launched from Finder inherits launchd's PATH, not"
    note "your shell's. Symlink it into one of those:"
    note "  ln -s \"$ALSO\" ~/.local/bin/claude"
  else
    warn "claude not found — both Claude accounts will be unusable"
    # The same line the app's Install button runs. See
    # `AccountReadiness.installCommand`, which is the one copy of it.
    note "npm install -g @anthropic-ai/claude-code"
    note "https://claude.com/claude-code"
  fi
fi

# Read the configured directories out of the shared preference domain, falling
# back to the same defaults the app uses. `defaults read` on a missing key exits
# non-zero, which is the "not configured" case.
DOMAIN="com.matthewquigley.honeycode"
claude_dir() {
  local account="$1" default="$2" set
  set="$(defaults read "$DOMAIN" "account.configDir.$account" 2>/dev/null)"
  if [[ -n "$set" ]]; then echo "${set/#\~/$HOME}"; else echo "$default"; fi
}

for pair in "personal:$HOME/.claude-personal:Claude Personal" \
            "work:$HOME/.claude:Claude Enterprise"; do
  ACCOUNT="${pair%%:*}"; REST="${pair#*:}"
  DEFAULT="${REST%%:*}"; LABEL="${REST#*:}"
  DIR="$(claude_dir "$ACCOUNT" "$DEFAULT")"
  if [[ -d "$DIR" ]]; then
    if [[ -f "$DIR/.credentials.json" ]] || [[ -d "$DIR/projects" ]]; then
      ok "$LABEL — $DIR"
    else
      warn "$LABEL — $DIR exists but holds no Claude login yet"
      note "CLAUDE_CONFIG_DIR=\"$DIR\" claude   then sign in"
    fi
  else
    warn "$LABEL — no directory at $DIR"
    note "With a single Claude login, point this account at ~/.claude too:"
    note "  Honeycode ▸ Settings ▸ Accounts, or"
    note "  defaults write $DOMAIN account.configDir.$ACCOUNT ~/.claude"
    note "Two separate logins live in two directories — sign the second in with"
    note "  CLAUDE_CONFIG_DIR=\"$DIR\" claude"
  fi
done

heading "Other agents"

# Both are optional, and both are ACP CLIs that keep their own credentials —
# there is no equivalent of CLAUDE_CONFIG_DIR to check, so all this can say is
# whether the binary exists.
for pair in "kimi:Kimi Code:npm install -g @moonshotai/kimi-cli" \
            "copilot:GitHub Copilot:npm install -g @github/copilot"; do
  TOOL="${pair%%:*}"; REST="${pair#*:}"
  LABEL="${REST%%:*}"; INSTALL="${REST#*:}"
  FOUND="$(find_tool "$TOOL" || true)"
  if [[ -n "$FOUND" ]]; then
    ok "$LABEL — $FOUND"
    note "Signed in? Run \`$TOOL\` once on its own and check."
  else
    ALSO="$(elsewhere "$TOOL" || true)"
    if [[ -n "$ALSO" ]]; then
      warn "$LABEL is at $ALSO, which is not where Honeycode looks"
      note "ln -s \"$ALSO\" ~/.local/bin/$TOOL"
    else
      warn "$LABEL not installed — the @$TOOL account will not start"
      note "$INSTALL"
    fi
  fi
done

if [[ -d "$HOME/.nvm/versions/node" ]] || command -v node >/dev/null 2>&1; then
  ok "node — Kimi's CLI is a Node program and needs it on the same PATH"
else
  warn "node not found — Kimi will not run without it"
fi

# ------------------------------------------------------------------ signing

heading "Code signing"

IDENTITY="Honeycode Local Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
  ok "'$IDENTITY' present — permission grants survive a rebuild"
else
  warn "no local signing identity — every build is a new program to macOS"
  note "You will be re-asked for Documents and Desktop access after each one."
  note "  ./tools/signing-identity.sh"
fi

# ------------------------------------------------------------------ verdict

heading "Result"

if (( FATAL > 0 )); then
  printf '  %s%d thing(s) must be fixed before Honeycode will build.%s\n\n' \
         "$RED" "$FATAL" "$RESET"
  exit 1
fi

if (( WARNED > 0 )); then
  printf '  Builds fine. %d thing(s) above limit what you can use.\n' "$WARNED"
else
  printf '  %sEverything Honeycode needs is here.%s\n' "$GREEN" "$RESET"
fi
printf '\n    %s./build.sh && ./build-ai.sh%s\n' "$BOLD" "$RESET"
printf '    %sopen %s/build/Honeycode.app%s\n\n' "$DIM" "$ROOT" "$RESET"
