#!/usr/bin/env python3
"""Score one crew run, from its log and the directory it built.

Everything here is counted from what the run actually printed and what is
actually on disk — never from what anybody in the run said about it, which is
the same rule `Crew.ledger` follows and for the same reason.

The headline number is the phase split. A crew is worth having because several
agents work at once; a run that spends most of its wall clock inside one agent
has the cost of a crew and the speed of a solo session, and that was true of
the first run this was built to measure: 28% of it had three agents in it and
72% had one. Nothing else here matters as much.

    tools/crewscore.py runs/<label>          score one run
    tools/crewscore.py --all                 every run, as a table
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ANSI = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]")
STAMPED = re.compile(r"^\s*([0-9.]+) \| (.*)$")

# Messages that carry no information — the failure mode where two agents spend
# paid turns being polite at each other. Matched on the whole line because the
# reporter truncates them, so only the opening survives.
CEREMONY = re.compile(
    r"\b(thanks|thank you|acknowledg\w*|noted|confirm\w*|understood|"
    r"nothing further|no changes|nothing here requires|all compatible|"
    r"not a question|already complete|matches the contract|"
    r"nothing to do|no action)\b", re.I)


def read(run):
    """Every log line as (seconds, text), colour stripped."""
    path = os.path.join(run, "log.txt")
    if not os.path.exists(path):
        return []
    out = []
    with open(path, errors="replace") as handle:
        for raw in handle:
            line = ANSI.sub("", raw.rstrip("\n"))
            match = STAMPED.match(line)
            if match:
                out.append((float(match.group(1)), match.group(2).rstrip()))
    return out


def built(work):
    """What is on disk, ignoring the noise a run leaves behind."""
    files, size = [], 0
    for base, dirs, names in os.walk(work):
        dirs[:] = [d for d in dirs if d not in {".git", "node_modules", "__pycache__"}]
        for name in names:
            if name == ".DS_Store":
                continue
            full = os.path.join(base, name)
            try:
                bytes_ = os.path.getsize(full)
            except OSError:
                continue
            files.append(os.path.relpath(full, work))
            size += bytes_
    return sorted(files), size


# A seat starts working when it is dispatched and stops at its own "done".
DISPATCH = re.compile(r"^▸ @(\S+)")
DONE = re.compile(r"^▸ (\S+) done$")
ASSEMBLING = re.compile(r"^▸ (\S+) assembling")


def concurrency(lines, seconds):
    """How many agents were actually working at once, over the whole run.

    The phase split this file was built around — everything before the lead
    starts assembling — turns out to flatter a run badly. It counts the lead's
    planning turn as parallel time because it happens before the boundary, and
    it counts a delegate that finished in the first minute as working for the
    whole phase because nothing marks it stopping.

    The run that exposed this scored 69% by that measure and had two agents
    running at once for 77 of its 1083 seconds. One delegate delivered in 78
    seconds and then sat idle for 505 while its neighbour worked alone, which
    is the shape of a crew being paid for and not used.

    So: build a busy interval per seat, and integrate. The lead is busy from
    the start until it dispatches, and again from `assembling` to the end; a
    delegate is busy from the dispatch that named it until it reports done.
    """
    if not lines or not seconds:
        return None

    dispatched, done, assemble_at = {}, {}, None
    for at, text in lines:
        if (m := DISPATCH.match(text)):
            dispatched.setdefault(m.group(1).lstrip("@"), at)
        elif (m := DONE.match(text)):
            done[m.group(1).lstrip("@")] = at
        elif ASSEMBLING.match(text) and assemble_at is None:
            assemble_at = at

    if not dispatched:
        return None

    first = min(dispatched.values())
    spans = [(0.0, first)]                       # the lead, planning
    if assemble_at is not None:
        spans.append((assemble_at, float(seconds)))   # the lead, assembling
    # A delegate with no "done" ran to the end of the crew phase — a watchdog
    # kill or a wedge. Charging it to `assemble_at` is the generous reading and
    # keeps a hung seat from looking like idle capacity.
    for seat, at in dispatched.items():
        spans.append((at, done.get(seat, assemble_at or float(seconds))))

    # Sweep the endpoints and weight each gap by how many spans cover it.
    edges = sorted({e for span in spans for e in span})
    busy_area, together = 0.0, 0.0
    for lo, hi in zip(edges, edges[1:]):
        n = sum(1 for a, b in spans if a <= lo and b >= hi)
        busy_area += n * (hi - lo)
        if n >= 2:
            together += hi - lo

    # Time a delegate spent finished while the run carried on without it.
    idle = sum(max(0.0, (assemble_at or seconds) - done[s])
               for s in dispatched if s in done)

    return {
        "together": round(together),
        "together_pct": round(100 * together / seconds),
        "avg_agents": round(busy_area / seconds, 2),
        "idle_seat_seconds": round(idle),
        "seats": len(dispatched) + 1,
    }


def score(run):
    lines = read(run)
    work = os.path.join(run, "work")
    meta = os.path.join(run, "meta.txt")
    timed_out = os.path.exists(meta) and "TIMED-OUT" in open(meta).read()

    text = [t for _, t in lines]
    joined = "\n".join(text)
    total = lines[-1][0] if lines else 0.0

    # The run's own closing line is the authority on both, when it got there.
    # The spend half is whatever `Crew.spend` decided to say — "$5.34", "15.33
    # AI units", or "no cost reported" for a subscription that bills nothing.
    # Matching only the money-shaped ones read a finished run as a wedged one.
    ended = re.search(r"^\s*(\d+)s · (.+)$", joined, re.M)
    seconds = int(ended.group(1)) if ended else round(total)
    spend = ended.group(2) if ended else None

    # First "assembling" is the moment the crew stops and the lead starts. Only
    # the first: later ones are the boundary of a later round, and the split
    # this measures is parallel-vs-solo across the whole run.
    solo_from = next((s for s, t in lines if re.search(r"\bassembling\b", t)), None)
    parallel = round(100 * solo_from / seconds) if solo_from and seconds else None

    def count(pattern):
        return len(re.findall(pattern, joined, re.I | re.M))

    messages = [t for t in text if re.search(r"@\S+\s*[→↩]\s*@", t)]

    result = {
        "run": os.path.basename(run),
        "seconds": seconds,
        "spend": spend,
        "wedged": timed_out or (not ended and bool(lines)),
        "parallel_pct": parallel,
        "rounds": max([int(m) for m in re.findall(r"assembling · round (\d+)", joined)]
                      or [1 if solo_from else 0]),
        # `joined` is the text with the stamp already stripped, so anchor on
        # what the reporter actually writes.
        "delegates": count(r"^▸ @"),
        "collisions": count(r"is named in .* pieces"),
        "messages": len(messages),
        "ceremony": sum(1 for m in messages if CEREMONY.search(m)),
        "empty_handed": count(r"finished without writing or running anything"),
        "gave_up": count(r"nothing from @\S+ for \d+ minutes"),
        "reissued": count(r"produced nothing — (asking|handing)"),
        "not_delivered": count(r"not delivered —"),
    }
    result["files"], result["bytes"] = built(work) if os.path.isdir(work) else ([], 0)
    result["concurrency"] = concurrency(lines, seconds)
    return result


def report(s):
    print(f"  {s['run']}")
    size = (f"{s['bytes'] // 1024}KB" if s["bytes"] >= 1024 else f"{s['bytes']}B")
    print(f"    {s['seconds']}s"
          + (f" · {s['spend']}" if s["spend"] else " · (no closing line)")
          + f" · {len(s['files'])} files, {size}")
    if s["wedged"]:
        print("    WEDGED — no closing line; the run never gave the prompt back")
    # The phase split is kept because it is comparable with earlier runs, but
    # it is no longer the headline: it reads a finished-and-idle delegate as a
    # working one. `together` is the honest version.
    if s["parallel_pct"] is not None:
        solo = 100 - s["parallel_pct"]
        print(f"    crew phase {s['parallel_pct']}% · lead alone {solo}%")
    if (c := s.get("concurrency")):
        print(f"    2+ agents at once: {c['together']}s = {c['together_pct']}%"
              f" · mean {c['avg_agents']} of {c['seats']} seats busy"
              + ("   <- the number that matters" if c["together_pct"] < 40 else ""))
        if c["idle_seat_seconds"]:
            print(f"    delegate idle after delivering: {c['idle_seat_seconds']}s"
                  " (finished early, never given more)")
    print(f"    rounds {s['rounds']} · delegates dispatched {s['delegates']}")

    # Only the things that were wrong. A clean run should say almost nothing,
    # or the signal goes the way of a compiler warning nobody reads.
    for label, key, why in [
        ("collision notices", "collisions", "files two pieces both named"),
        ("empty-handed", "empty_handed", "delegates that wrote nothing"),
        ("gave up", "gave_up", "watchdog fired"),
        ("re-issued", "reissued", "pieces handed out again"),
        ("undelivered", "not_delivered", "messages that reached nobody"),
    ]:
        if s[key]:
            print(f"    {label}: {s[key]}  ({why})")
    if s["messages"]:
        note = f"    crew messages: {s['messages']}"
        if s["ceremony"]:
            note += f", {s['ceremony']} of them ceremony (thanks/acknowledged/noted)"
        print(note)


def main():
    args = sys.argv[1:]
    if args and args[0] == "--all":
        base = os.path.join(ROOT, "runs")
        runs = sorted(os.path.join(base, d) for d in os.listdir(base)) \
            if os.path.isdir(base) else []
        if not runs:
            print("no runs yet — tools/crewlab.sh \"<task>\"")
            return
        for run in runs:
            report(score(run))
            print()
        return

    if not args:
        print(__doc__.strip())
        sys.exit(2)

    run = args[0]
    if not os.path.isdir(run):
        print(f"no such run: {run}", file=sys.stderr)
        sys.exit(1)
    s = score(run)
    report(s)
    with open(os.path.join(run, "score.json"), "w") as handle:
        json.dump(s, handle, indent=2)


if __name__ == "__main__":
    main()
