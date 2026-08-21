#!/usr/bin/env bash
# Run one crew task headlessly, and keep everything needed to judge it.
#
# The loop this exists for is: change `Crew`, run a real crew against a real
# task, read what it did, change `Crew` again. Everything in that loop except
# the reading was manual — open the app, type a prompt, watch, then dig the
# numbers out of a session JSON afterwards. This does the same run from a
# shell, timestamps every line as it arrives, and scores it.
#
# `ai -p` is the whole trick: it is the same engine the window drives, minus
# the window. `Console` and `Progress` already fall back to plain output when
# stdout isn't a terminal, so piping it to a file needs no flag.
#
#   tools/crewlab.sh "build a snake game. html"
#   tools/crewlab.sh --crew "@kimi @kimi#2" --name two-seats "build snake"
#   tools/crewlab.sh --dry-run "…"          print the command, spend nothing
#
# THIS SPENDS REAL MONEY on real subscriptions — a three-seat run of a
# game-sized task has cost $5–7 and taken half an hour. `--dry-run` first if
# you are unsure what it will do.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREW="@kimi @kimi#2 @kimi#3"
NAME=""
TIMEOUT=2400
DRY=0
PROMPT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --crew)     CREW="$2"; shift 2 ;;
    --name)     NAME="$2"; shift 2 ;;
    --timeout)  TIMEOUT="$2"; shift 2 ;;
    --dry-run)  DRY=1; shift ;;
    -h|--help)
      sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *)  PROMPT="${PROMPT:+$PROMPT }$1"; shift ;;
  esac
done

[[ -n "$PROMPT" ]] || { echo "usage: tools/crewlab.sh [options] \"<task>\"" >&2; exit 2; }
[[ -x "$ROOT/build/ai" ]] || { echo "build/ai missing — run ./build-ai.sh first" >&2; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
LABEL="${NAME:+$NAME-}$STAMP"
RUN="$ROOT/runs/$LABEL"
WORK="$RUN/work"
LOG="$RUN/log.txt"

# The crew goes last. `AgentMention.parse` strips mentions from anywhere in the
# message, but a task that reads as a sentence is what a person would type, and
# the point of this harness is to reproduce that rather than something tidier.
MESSAGE="$PROMPT $CREW"

if [[ $DRY -eq 1 ]]; then
  echo "would run, in $WORK:"
  echo "  ai -p \"$MESSAGE\""
  echo "  timeout ${TIMEOUT}s, log → $LOG"
  exit 0
fi

mkdir -p "$WORK"
{
  echo "task:    $PROMPT"
  echo "crew:    $CREW"
  echo "work:    $WORK"
  echo "started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "commit:  $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '(none)')"
  echo "---"
} > "$RUN/meta.txt"

echo "==> $LABEL"
echo "    $MESSAGE"
echo "    work: $WORK"
echo "    log:  $LOG"

# Every line stamped with seconds since launch. This is the only way the phase
# split — how much of the run had four agents in it and how much had one — can
# be recovered afterwards, and it is the number the whole exercise is about.
# Unbuffered on both sides or the stamps measure when the pipe flushed.
(
  cd "$WORK"
  "$ROOT/build/ai" -p "$MESSAGE" 2>&1
) | python3 -u -c '
import sys, time
start = time.time()
for line in sys.stdin:
    sys.stdout.write("%8.2f | %s" % (time.time() - start, line))
' | tee "$LOG" &

PIPE=$!
WAITED=0
while kill -0 "$PIPE" 2>/dev/null; do
  if [[ $WAITED -ge $TIMEOUT ]]; then
    echo "==> timed out after ${TIMEOUT}s — killing" | tee -a "$LOG"
    # The whole tree: `ai` spawns a CLI per seat and killing the pipeline
    # leader would orphan them, which is how you end up with four Kimis still
    # running against your subscription after the harness has exited.
    pkill -P "$PIPE" 2>/dev/null || true
    kill "$PIPE" 2>/dev/null || true
    pkill -f "$ROOT/build/ai" 2>/dev/null || true
    echo "TIMED-OUT" >> "$RUN/meta.txt"
    break
  fi
  sleep 5
  WAITED=$((WAITED + 5))
done
wait "$PIPE" 2>/dev/null || true

echo
python3 "$ROOT/tools/crewscore.py" "$RUN"
