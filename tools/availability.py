#!/usr/bin/env python3
"""What the deployment target would have to be, from Apple's own availability
data rather than from a compiler.

`build.sh` defaults to macOS 26.0 and nothing in the source says why: there is
not one `@available` in it. The authoritative answer is `swiftc` rejecting
things at a lower target, which needs a Mac. This needs a network.

    ./tools/availability.py                # what sits above macOS 14
    ./tools/availability.py --floor 15.0   # or above some other floor
    ./tools/availability.py --all          # everything it resolved
    ./tools/availability.py --refresh      # ignore the cache

Two sources, because neither is enough on its own:

  * Apple's navigator index (`/tutorials/data/index/<framework>`) is one
    request per framework and covers types well. It covers *View modifiers*
    badly — of 113 modifiers this app chains, the index knows 17. It also
    omits `glassEffect` entirely, which is the single most important symbol
    here, so an index miss means nothing at all.

  * So modifiers are resolved by trying signatures against
    `/documentation/swiftui/view/<name><signature>.json` until one answers.
    A modifier whose signature is not in `SIGNATURES` goes unresolved.

**An unresolved symbol has not been cleared.** It is a symbol this could not
ask about. The report says how many there are for exactly that reason, and the
number is not small. What this produces is a floor that is a *lower bound* —
everything it names really is that tall, and there may be more it could not
see.
"""
import argparse
import json
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE = Path(os.environ.get("TMPDIR", "/tmp")) / "honeycode-availability"
BASE = "https://developer.apple.com/tutorials/data"

# AgentKit links none of these, which is why it isn't swept — and is also why
# `ai` is the better bet on an old Mac.
FRAMEWORKS = ["swiftui", "appkit", "charts", "webkit", "speech",
              "avfoundation", "combine", "foundation"]

# Tried in this order against `swiftui/view/<name>…`. Ordered by how often they
# turn out to be the answer, so the common case costs one request.
SIGNATURES = [
    "(_:)", "()", "(_:_:)", "(_:in:)", "(_:anchor:)", "(_:axes:)",
    "(_:perform:)", "(_:initial:)", "(_:initial:_:)", "(for:of:action:)",
    "(_:value:)", "(_:alignment:)", "(_:content:)", "(id:anchor:)",
    "(_:isenabled:)", "(_:_:_:)", "(_:isactive:)", "(_:isprsented:)",
    "(_:includingchildren:)", "(_:options:)", "(_:style:)", "(_:width:)",
]


def fetch(url, into):
    """curl, because it reads the system proxy configuration and trust store."""
    into.parent.mkdir(parents=True, exist_ok=True)
    if into.exists():
        raw = into.read_bytes()
        return raw if raw else None
    done = subprocess.run(["curl", "-sS", "--max-time", "40", "-o", str(into), url],
                          capture_output=True)
    if done.returncode != 0:
        into.unlink(missing_ok=True)
        return None
    return into.read_bytes() or None


def introduced(path):
    """The macOS version a documented symbol arrived in, or None."""
    slug = path.strip("/").replace("/", "-").replace("(", "").replace(")", "")
    raw = fetch(f"{BASE}{path}.json", CACHE / f"sym-{slug}.json")
    if raw is None:
        return None
    try:
        page = json.loads(raw)
    except ValueError:
        return None
    for platform in page.get("metadata", {}).get("platforms") or []:
        if platform.get("name") == "macOS":
            return platform.get("introducedAt")
    return None


# ---------------------------------------------------------------- the source

DECLARED = re.compile(
    r"^\s*(?:public |private |internal |fileprivate |static |final |@\w+\s+)*"
    r"(?:func|var|let|case|struct|class|enum|protocol|typealias|extension)\s+"
    r"([A-Za-z_][A-Za-z0-9_]*)", re.M)


def strip(text):
    """Comments and string literals. This codebase names APIs constantly in
    prose, and counting those would report symbols nothing calls."""
    text = re.sub(r"^\s*///?.*$", "", text, flags=re.M)
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r'"(?:[^"\\\n]|\\.)*"', '""', text)


def survey():
    app = sorted((ROOT / "Sources" / "Honeycode").glob("*.swift"))
    every = app + sorted((ROOT / "Sources" / "AgentKit").glob("*.swift")) \
                + sorted((ROOT / "Sources" / "ai").glob("*.swift"))
    if not app:
        sys.exit("no sources found — run this from the repo")

    mine = set()
    for path in every:
        mine |= set(DECLARED.findall(path.read_text()))

    modifiers, types = set(), set()
    for path in app:
        text = strip(path.read_text())
        # A modifier at the head of a chained line. Precise almost to a fault:
        # it misses inline `.foo(…)` mid-expression, and it does not invent.
        modifiers |= set(re.findall(r"^\s*\.([a-z][A-Za-z0-9]*)\s*\(", text, re.M))
        modifiers |= set(re.findall(r"^\s*\.([a-z][A-Za-z0-9]*)\s*$", text, re.M))
        types |= set(re.findall(r"\b([A-Z][A-Za-z0-9]*)\b", text))
    return app, mine, modifiers - mine, types - mine


def catalogue():
    """title -> doc paths, from every framework's navigator index."""
    found = {}

    def walk(nodes):
        for node in nodes:
            path, title = node.get("path"), node.get("title")
            if path and title:
                found.setdefault(title.split("(")[0], []).append(path)
            walk(node.get("children", []))

    for framework in FRAMEWORKS:
        raw = fetch(f"{BASE}/index/{framework}", CACHE / f"index-{framework}.json")
        if raw is None:
            continue
        try:
            tree = json.loads(raw)
        except ValueError:
            continue
        for roots in tree.get("interfaceLanguages", {}).values():
            walk(roots)
    return found


def lowest(paths):
    """The oldest macOS across a set of doc paths, and which one it was.

    The oldest, not the first, and that is the whole correctness of this.
    `.gesture(WindowDragGesture())` looks like `gesture(_:)`, which Apple
    introduced in macOS 26 — but `gesture(_:including:)` is 10.15 and is what
    the call actually resolves to. Reporting the first signature that answered
    would have called that a blocker, which is how a tool like this loses the
    right to be believed.
    """
    found = [(number(v), v, p) for p, v in
             ((p, introduced(p)) for p in paths) if v]
    if not found:
        return None, None, 0
    found.sort()
    return found[0][1], found[0][2], len(found)


def probe(name):
    """A View modifier: every signature Apple answers to, oldest wins."""
    return lowest([f"/documentation/swiftui/view/{name.lower()}{signature}"
                   for signature in SIGNATURES])


def number(text):
    try:
        return tuple(int(part) for part in str(text).split("."))
    except (TypeError, ValueError):
        return (0,)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--floor", default="14.0")
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--refresh", action="store_true")
    args = parser.parse_args()

    if args.refresh and CACHE.exists():
        for stale in CACHE.glob("*.json"):
            stale.unlink()

    app, mine, modifiers, types = survey()
    print(f"  {len(app)} files in Sources/Honeycode · {len(modifiers)} chained "
          f"modifiers · {len(types)} type names")
    print(f"  discounting {len(mine)} names the project declares itself\n")

    known = catalogue()
    print(f"  {len(known)} symbols across {len(FRAMEWORKS)} navigator indexes")

    resolved, unresolved = {}, []

    # Types, from the index. Same rule: a name that means several things is
    # only as tall as the oldest of them, because this cannot tell which one
    # the source meant.
    named = [n for n in sorted(types) if n in known]
    with ThreadPoolExecutor(max_workers=8) as pool:
        answers = pool.map(lambda n: lowest(known[n][:6]), named)
        for name, (version, path, count) in zip(named, answers):
            if version:
                resolved[name] = (version, path, count)
            else:
                unresolved.append(name)
    unresolved += [n for n in sorted(types) if n not in known]

    # Modifiers, by probing every signature.
    names = sorted(modifiers)
    with ThreadPoolExecutor(max_workers=8) as pool:
        for name, (version, path, count) in zip(names, pool.map(probe, names)):
            if version:
                resolved[name] = (version, path, count)
            else:
                unresolved.append(name)
    print(f"  {len(resolved)} carried a macOS version, {len(unresolved)} could "
          f"not be asked\n")

    floor = number(args.floor)
    rows = sorted(((number(v), n, v, p, c) for n, (v, p, c) in resolved.items()),
                  reverse=True)
    over = [r for r in rows if r[0] > floor]

    print(f"  ── above macOS {args.floor} " + "─" * 46)
    if not over:
        print(f"     nothing this could resolve.")
    for _, name, version, path, count in over:
        spread = "" if count == 1 else f"  (oldest of {count} overloads)"
        print(f"     {name:<30} macOS {version:<6} {path}{spread}")

    print(f"\n  ── the tallest within macOS {args.floor} " + "─" * 33)
    for _, name, version, path, _c in [r for r in rows if r[0] <= floor][:10]:
        print(f"     {name:<30} macOS {version}")

    if args.all:
        print("\n  ── everything resolved " + "─" * 47)
        for _, name, version, path, _c in rows:
            print(f"     {name:<30} macOS {version}")
        print("\n  ── could not be asked " + "─" * 48)
        for name in sorted(unresolved):
            print(f"     {name}")

    print(f"\n  {len(unresolved)} symbols went unresolved and are NOT cleared by "
          f"this — see\n  the caveats at the top of this file. The floor above is "
          f"a lower bound.")


if __name__ == "__main__":
    main()
