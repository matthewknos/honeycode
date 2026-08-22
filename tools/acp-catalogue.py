#!/usr/bin/env python3
"""Regenerate Sources/AgentKit/AgentCatalogue.swift from the ACP registry.

Honeycode can drive any CLI that speaks the Agent Client Protocol, and until
now the only way to add one was to know its command and type six fields. The
registry behind zed.dev/acp is the canonical list of those CLIs and it is
machine-readable, so the catalogue is generated from it rather than curated by
hand and left to rot.

Generated rather than fetched at runtime, deliberately. The app makes no
outbound requests of its own — the first-run flow says in as many words that
nothing leaves your Mac except through the agent CLIs themselves — and a
network call for a list of names is not worth making that sentence false. The
cost is that this has to be re-run; the benefit is that it can be read in a
diff.

    ./tools/acp-catalogue.py            # rewrite the Swift file
    ./tools/acp-catalogue.py --dry-run  # print what would change

Versions are stripped from package specs on purpose. The registry pins them so
that Zed can install a known-good build; here the package name reaches `npx`,
which should fetch whatever is current rather than whatever was current the day
this file was regenerated.
"""

import json, re, shutil, subprocess, sys
from pathlib import Path

REGISTRY = "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json"
OUT = (Path(__file__).resolve().parent.parent
       / "Sources/AgentKit/AgentCatalogue+Generated.swift")

# Already built in, and a second row for either would be the same subscription
# under two names. See `Account.allCases`.
SKIP = {"kimi", "github-copilot-cli"}

# The ones most people are looking for, in front.
#
# This is a judgement and it is the only one in this file, so it is worth being
# plain about. Nothing is filtered — every agent in the registry is in the list
# — but strict alphabetical order opened it on an agent marketplace that
# settles payments in USDC, with Gemini, Codex and Cursor below the fold. A
# list you have to scroll past a stranger to find what you came for is a list
# that reads as a dump.
#
# So: recognisable names first, in roughly the order somebody would think of
# them, and everything else alphabetically after. Anything dropped from the
# registry simply falls out of this; anything added lands in the alphabetical
# tail, which is the safe place for a name nobody has vouched for.
FIRST = [
    "gemini", "codex-acp", "claude-acp", "cursor", "opencode", "cline",
    "goose", "qwen-code", "amp-acp", "factory-droid", "auggie", "devin",
    "mistral-vibe", "grok-build", "kilo", "antigravity-acp",
]

# A release-artefact name is not a command. `pool-darwin-arm64` is what the
# tarball unpacks to, not what lands on anybody's PATH, so an entry whose
# executable is named after a platform is one this cannot honestly describe.
ARCH = re.compile(r"(darwin|linux|windows|arm64|aarch64|amd64|x86[_-]?64)", re.I)


def unpinned(spec):
    """`@google/gemini-cli@0.56.0` -> `@google/gemini-cli`."""
    at = spec.rfind("@")
    return spec[:at] if at > 0 else spec


def launch(agent):
    """How to start this one, or None if it cannot be said.

    Three shapes come out of the registry. `npx` and `uvx` are the good case:
    the runner fetches the package on first use, so adding the account is the
    whole of the job and there is nothing to install. A binary distribution
    means the tool installs itself, and all that can be taken from it is the
    executable's name and its arguments — Honeycode looks for that on your
    PATH the same way it looks for `kimi`.
    """
    dist = agent.get("distribution", {})
    if "npx" in dist:
        d = dist["npx"]
        package = unpinned(d["package"])
        return dict(command="npx", arguments=["-y", package] + (d.get("args") or []),
                    isNode=True, environment=d.get("env") or {}, site=None)
    if "uvx" in dist:
        d = dist["uvx"]
        package = d["package"].split("==")[0]
        return dict(command="uvx", arguments=[package] + (d.get("args") or []),
                    isNode=False, environment=d.get("env") or {}, site=None)
    binary = dist.get("binary", {}).get("darwin-aarch64")
    if not binary:
        return None
    cmd = binary.get("cmd", "")
    # The executable's own name is usable — `./goose`, and `./bin/devin` or
    # `./dist-package/cursor-agent`, whose enclosing directory is an artefact of
    # the tarball rather than part of the name. What isn't:
    # `./Applications/junie.app/Contents/MacOS/junie`, which is a layout inside
    # an archive this app never unpacks, and `./pool-darwin-arm64`, which is a
    # release filename and not what lands on anybody's PATH.
    stem = cmd[2:] if cmd.startswith("./") else cmd
    parts = [p for p in stem.split("/") if p]
    if not parts or len(parts) > 2 or ARCH.search(parts[-1]):
        return None
    stem = parts[-1]
    site = agent.get("website") or agent.get("repository")
    return dict(command=stem, arguments=binary.get("args") or [], isNode=False,
                environment=binary.get("env") or {}, site=site)


def handle(agent):
    """What it answers to after an `@`.

    From the registry id, which is already a slug, with the suffixes that say
    "this is the ACP build of the thing" removed — you type the tool's name,
    not its integration's.
    """
    slug = re.sub(r"[^a-z0-9-]", "-", agent["id"].lower())
    slug = re.sub(r"-(acp|cli)$", "", slug)
    slug = re.sub(r"-+", "-", slug).strip("-")
    return slug or agent["id"]


def swift(text):
    return text.replace("\\", "\\\\").replace('"', '\\"')


def blurb(agent):
    text = " ".join((agent.get("description") or "").split())
    return text if len(text) <= 130 else text[:129].rstrip(" ,.;") + "…"


def fetch(url):
    """Through `curl` rather than `urllib`.

    Not a preference. `curl` reads the system proxy configuration and the
    system trust store, and this has to run on machines that sit behind both.
    """
    if not shutil.which("curl"):
        sys.exit("curl not found — it is how this fetches the registry.")
    done = subprocess.run(["curl", "-fsSL", url], capture_output=True, text=True)
    if done.returncode != 0:
        sys.exit(f"could not fetch {url}: {done.stderr.strip() or done.returncode}")
    return json.loads(done.stdout)


def main():
    registry = fetch(REGISTRY)

    def order(agent):
        try:
            return (0, FIRST.index(agent["id"]), "")
        except ValueError:
            return (1, 0, agent["name"].lower())

    rows, skipped = [], []
    for agent in sorted(registry["agents"], key=order):
        if agent["id"] in SKIP:
            continue
        run = launch(agent)
        if not run:
            skipped.append(agent["name"])
            continue
        rows.append((agent, run))

    lines = [
        "// Generated by tools/acp-catalogue.py from the Agent Client Protocol",
        f"// registry at {REGISTRY}.",
        f"// Registry version {registry.get('version', 'unknown')}, "
        f"{len(rows)} agents. Do not edit by hand — re-run the script.",
        "",
        "import Foundation",
        "",
        DOC,
        "extension AgentCatalogue {",
        "",
        "    static let all: [CatalogueAgent] = [",
    ]
    for agent, run in rows:
        args = ", ".join(f'"{swift(a)}"' for a in run["arguments"])
        env = ", ".join(f'"{swift(k)}": "{swift(v)}"'
                        for k, v in sorted(run["environment"].items()))
        site = f'"{swift(run["site"])}"' if run["site"] else "nil"
        lines += [
            "        CatalogueAgent(",
            f'            id: "{swift(agent["id"])}",',
            f'            name: "{swift(agent["name"])}",',
            f'            handle: "{swift(handle(agent))}",',
            f'            blurb: "{swift(blurb(agent))}",',
            f'            command: "{swift(run["command"])}",',
            f"            arguments: [{args}],",
            f"            isNode: {'true' if run['isNode'] else 'false'},",
            f"            environment: [{env if env else ':'}],",
            f"            site: {site}),",
        ]
    lines += ["    ]", "}", ""]

    text = "\n".join(lines)
    if "--dry-run" in sys.argv:
        print(text)
    else:
        OUT.write_text(text)
        print(f"wrote {OUT.relative_to(Path.cwd())} — {len(rows)} agents")
    if skipped:
        print("no launchable command, left out: " + ", ".join(sorted(skipped)),
              file=sys.stderr)


DOC = """\
/// Every agent in the registry, as of the last time the script was run.
///
/// Data only — `AgentCatalogue.swift` holds the type and the reasoning, and
/// `tools/acp-catalogue.py` holds the rules about what is left out."""


if __name__ == "__main__":
    main()
