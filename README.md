# Honeycode

A macOS client that puts every coding subscription you pay for in one window,
and lets them work as a crew.

Name several accounts in one message and the first one named leads. It plans the
work, hands pieces to the others, waits for them, and assembles what comes back:

```
a one-page site for a dentist @claude-p @claude-w @kimi
```

That is the whole idea. Everything else in here exists to make that safe, legible
and repeatable — a tenancy fence so enterprise work doesn't leak onto a personal
subscription, a live panel so you can see what four agents are doing at once, and
a channel the agents use to ask each other questions mid-run.

There are two faces on the same engine:

- **Honeycode.app** — the window. Sessions, transcripts, a live crew panel.
- **`ai`** — the same thing in a terminal, including `ai -p "…"` for one message
  and out, so anything that can run a program can hand work to your subscriptions.

Both link `AgentKit`, which is the engine and has no UI in it.

---

## Requirements

| | |
|---|---|
| **Mac** | Apple silicon, macOS 26 or later |
| **Toolchain** | Xcode Command Line Tools (`xcode-select --install`). Full Xcode is not required and there is no `.xcodeproj` — each target is one `swiftc` invocation. |
| **At least one agent CLI** | See below. The app is useful with one; it is interesting with three. |

The agent CLIs are the actual coding agents. Honeycode drives them, it does not
replace them — it never talks to a model endpoint directly.

| Account | CLI | Install |
|---|---|---|
| `@claude-p` Claude Personal | `claude` | [claude.com/claude-code](https://claude.com/claude-code) |
| `@claude-w` Claude Enterprise | `claude` | same binary, different login — see [Accounts](#accounts) |
| `@kimi` Kimi Code | `kimi` | [MoonshotAI/kimi-cli](https://github.com/MoonshotAI/kimi-cli) (Node) |
| `@copilot` GitHub Copilot | `copilot` | [github/copilot-cli](https://github.com/github/copilot-cli) |

You can add others — see [Adding your own account](#adding-your-own-account).

---

## Setup

```sh
git clone <this repo> honeycode
cd honeycode
./tools/doctor.sh
```

`doctor.sh` changes nothing. It checks the toolchain, looks for each agent CLI in
**the same places the app looks**, checks whether each Claude account has a config
directory with a login in it, and prints the one command that fixes whatever it
found. Start there — it catches the two failures that are otherwise baffling
(see [Troubleshooting](#troubleshooting)).

Then, once:

```sh
./tools/signing-identity.sh    # optional, and you want it — see below
./build.sh                     # build/Honeycode.app
./build-ai.sh                  # build/ai
open build/Honeycode.app
```

### Why the signing step

Without a signing identity, `build.sh` signs the app ad-hoc. An ad-hoc signature
makes the app's designated requirement nothing but its own code hash, and that
hash changes with every build — so macOS treats each build as a brand new program
and asks again for Documents and Desktop access, every single time.

`tools/signing-identity.sh` creates a self-signed certificate in your login
keychain and pins the requirement to the bundle identifier instead, so the
permissions you grant once stay granted. The certificate is local, means nothing
to anyone else's Mac, and signs nothing but this app. It asks for your login
password once.

### Putting `ai` on your PATH

```sh
ln -s "$PWD/build/ai" ~/.local/bin/ai
```

---

## Accounts

### The two Claude accounts

Claude Code stores its login in a directory, and `CLAUDE_CONFIG_DIR` picks which
one. That is the *entire* mechanism for having two Claude accounts — there is no
account switcher, there is a directory.

Honeycode ships pointing at:

| Account | Default directory |
|---|---|
| `@claude-w` Claude Enterprise | `~/.claude` |
| `@claude-p` Claude Personal | `~/.claude-personal` |

`~/.claude` is where the CLI puts a login by default. `~/.claude-personal` exists
only on a machine that has two Claude accounts and moved one out of the way.

**If you have one Claude account, point both at `~/.claude`** — or just use the
one and ignore the other. Both paths are editable in **Settings ▸ Accounts**, with
a checkmark beside each that tells you whether the directory is actually there.

**If you have two**, sign the second one in like this:

```sh
CLAUDE_CONFIG_DIR="$HOME/.claude-personal" claude
```

...and then use that shell whenever you want to touch that login. Honeycode sets
the variable itself for every session it launches.

### Kimi and Copilot

These keep their own credentials and have no equivalent knob. Run `kimi` or
`copilot` once in a terminal, sign in there, and Honeycode picks it up.

### Adding your own account

**Settings ▸ Accounts ▸ Add** takes any CLI that speaks ACP — the Agent Client
Protocol, newline-delimited JSON-RPC 2.0 over stdio. A Gemini CLI, a second Kimi
seat on a different key, an in-house agent, a Claude Code pointed at a proxy. You
give it:

- a **name**, a **handle** (`@gemini`) and a colour;
- the **command** and its **arguments** (`kimi acp`, `copilot --acp`);
- whether it's a **Node program** — this matters, see
  [Troubleshooting](#troubleshooting);
- which **dialect** of ACP it speaks — `standard` is the right guess for anything
  written against the spec; `configOptions` is Kimi's spelling;
- whether it reports **usage**, so the app knows whether `/usage` will be
  understood or just reach the model as a puzzled prompt;
- any **environment variables** it needs, including **API keys**.

API keys go in the **Keychain**, not in preferences. Only the *names* of the
secret variables are stored in the plist; the value is read at the moment a
process is launched and handed to that process, and never held in memory
otherwise.

One thing this deliberately isn't: a key on its own does not make an agent. The
thing that reads your files, runs your commands and decides what to edit is the
CLI. A key is how that CLI authenticates. Pointing Honeycode at a bare model
endpoint would mean writing the agent loop here, which is a different program.

---

## Using it

### The window

```
┌──────────────────────────────────────────────────────────────┐
│  sidebar   │  ● session · ~/proj · main   @chips  ⌸  ⋯  │  W  │
│  Code      │                                            │  o  │
│  Crew      │  transcript                                │  r  │
│  Agents    │                                            │  k  │
│  ────────  │                                            │  b  │
│  sessions  │  ┌──────────────────────────────────────┐  │  e  │
│            │  │ composer                             │  │  n  │
│  identity  │  └──────────────────────────────────────┘  │  c  │
│  settings  │                                            │  h  │
└──────────────────────────────────────────────────────────────┘
```

Three modes in the sidebar. **Code** is conversations, one column each, up to
three side by side. **Crew** is who is running right now across every session,
what each subscription can do and what it has left, and your saved teams.
**Agents** is the ones that run on their own.

Every column carries a **header bar**: which conversation, which folder, which
branch, whether it's fenced, what it's doing, who else is on the message and
what it has spent.

The **workbench** down the trailing edge has four tabs — **Preview** (a page, a
dev server or a rendered artifact), **Changes** (every file this session edited,
with diffs and the way to a pull request), **Files** (the working directory),
and **Run** (the crew, live). One panel, one width, one close; a badge on the
button counts the files edited so far.

Who you're signed in to GitHub and Azure as sits at the foot of the sidebar,
and switches from there.

### Mentions

```
@kimi rewrite this test                       one agent
@claude-w plan it @kimi @copilot              a crew — claude-w leads
@kimi @kimi#2 @kimi#3                         three separate Kimi conversations
```

A handle with no number is seat 1. `@kimi#2` is a **second instance of the same
subscription** — its own conversation, its own working directory, addressable on
its own. Up to four seats per account. This is how you get parallelism out of one
subscription: three Kimis with three different pieces, not one Kimi with three
tasks queued behind each other.

In the app you don't type any of this. The **Team** control in each column's
header bar builds the mention list for you — accounts, seats and models — and
the composer's `@` button opens the same list for a file or an agent by hand.

### Picking a model, and how hard it thinks

A colon after any handle:

```
@kimi:k3            any part of the title or id
@copilot:free       cheapest that costs no quota at all
@copilot:cheap      lowest usage multiplier on offer
@copilot:best       the strongest available
@claude-w:haiku     exact ids work too
@claude-p:opus:max  model and reasoning effort, in either order
```

Effort is `low · medium · high · xhigh · max`, and is a Claude concept only — ACP
has no equivalent, so the control isn't offered where it would be wired to
nothing. A choice sticks for the session and becomes that account's default.

```sh
ai --models [account]     what's on offer, from a shell
ai --describe             all of it as JSON, for other tools
```

### What a crew actually does

Three turns:

1. **The lead plans.** It emits an assignment block naming who gets what.
2. **The delegates work,** each in its own session, in parallel. They can ask
   each other questions mid-run through a message channel; the first message
   between any two agents is free, after that there's a budget, because otherwise
   four agents will happily talk to each other instead of working.
3. **The lead assembles** what came back.

Both channels are fenced blocks the agents write, and both are hidden from the
transcript — you see the plan and the work, not the plumbing. A delegate that
comes back empty-handed is noticed and its piece is handed out once more; a
delegate that correctly reports "nothing to do, this was already built" is not.

The **Run** tab of the workbench shows every seat, what it's on, what it's
touched and what the run has cost, live — and a banner above the composer says a
run has started if you're looking elsewhere. The **Crew** page in the sidebar
shows every run in the window at once, along with what each subscription can
run and how much of it is left.

### The tenancy fence

Enterprise work is licensed to somebody other than you, and a crew is a relay
nobody called one: `@claude-w plan this, @kimi do the pieces` hands enterprise
material to a personal subscription.

So before an off-tenant piece is dispatched, an ephemeral turn *on the enterprise
account* inspects the task text, and a task that fails inspection is not sent.
Files are fenced separately and harder: an off-tenant delegate gets an empty
scratch directory of its own and cannot read outside it. That is a real
restriction, and it is the point — the pieces you can safely hand outside the
tenancy are the ones that don't need the tenant's files.

It fails closed. An inspection that times out, returns nothing, or returns
something unparseable blocks the assignment.

---

## Where your data lives

| | |
|---|---|
| Sessions, artifacts, crew scratch directories | `~/Library/Application Support/Honeycode/` (0700) |
| Preferences, model catalogues, spend totals | `com.matthewquigley.honeycode` — one domain shared by the app and `ai` |
| Custom account API keys | login Keychain, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` |
| Agent credentials | wherever each agent CLI keeps them; Honeycode never copies them |

Nothing leaves your machine except through the agent CLIs themselves.

---

## Repo layout

```
Sources/AgentKit/     the engine — sessions, adapters, crew, tenancy
Sources/Honeycode/    the app (SwiftUI/AppKit)
Sources/ai/           the terminal client
Tests/                one main.swift per suite, no framework
Resources/            Info.plist, entitlements, icon, syntax themes
tools/                doctor.sh, signing-identity.sh
build.sh              → build/Honeycode.app
build-ai.sh           → build/ai
test.sh               everything; --typecheck for a fast loop
```

**`AgentKit` must not import SwiftUI, AppKit, WebKit, Charts or Quartz.** It's the
half that has to run without a UI. Nothing in the language enforces that —
SwiftUI imports perfectly well into a background process and drags AppKit along
behind it — so `build.sh` and `test.sh` both check, and both fail the build. It
has caught exactly one violation, in the direction you'd expect: a `Color` on
`Account`.

### Tests

```sh
./test.sh              everything
./test.sh --typecheck  both targets compile, nothing runs
```

Suites are plain `main.swift` files that print `ok`/`FAIL` and exit non-zero,
compiled against the real sources rather than a copy of their logic. There's no
test framework for the same reason there's no package manifest: a target is one
`swiftc` invocation, and a second tool would be more machinery than the thing it
tests.

`test.sh` writes nothing into `build/` and never stops a running app, so it's
safe to run while you're using the thing it's testing. `build.sh` does quit
Honeycode, because it has to overwrite the binary the running copy has mapped.

---

## Troubleshooting

**"It works in my terminal but Honeycode says it can't find `kimi`."**
An app launched from Finder inherits launchd's `PATH`, which is
`/usr/bin:/bin:/usr/sbin:/sbin` — no Homebrew, no nvm, nothing you put in your
shell profile. Honeycode therefore searches absolute paths: `~/.local/bin`,
`/opt/homebrew/bin`, `/usr/local/bin`, and the nvm tree. If your tool is
somewhere else, symlink it:

```sh
ln -s "$(command -v kimi)" ~/.local/bin/kimi
```

`./tools/doctor.sh` reports exactly this case.

**"A Node agent starts, thinks for a while, and returns nothing."**
Node ships its own CA list and ignores the system keychain. Behind a TLS-
inspecting proxy — Zscaler and friends — every request it makes fails with
`unable to get local issuer certificate`, and in ACP that failure is *silent*:
the OAuth refresh fails, the turn ends with `stopReason: end_turn` and no
content, and the agent looks like it simply had nothing to say.

Honeycode handles this by setting `NODE_EXTRA_CA_CERTS` from the system trust
store for any agent marked as a Node program — which is why that checkbox exists
when you add your own. It only ever *adds* roots the OS already trusts, and never
overrides a value you set yourself.

**"macOS keeps asking for Documents and Desktop access after every build."**
Run `./tools/signing-identity.sh`. See [Why the signing step](#why-the-signing-step).

**"A Claude account won't authenticate."**
Check the config directory in **Settings ▸ Accounts** actually exists and holds a
login. A directory that has never existed produces a failure that reads like an
auth problem rather than a configuration one. `./tools/doctor.sh` distinguishes
the two.

---

## Third-party code

One vendored library, and no dependency manager — a target here is one `swiftc`
invocation, and SwiftPM would be more machinery than this needs.

| | |
|---|---|
| [Highlightr](https://github.com/raspu/Highlightr) | MIT — `Sources/Honeycode/Vendor/Highlightr/` |
| [highlight.js](https://highlightjs.org) | BSD-3-Clause — `Resources/Highlight/highlight.min.js` |

Both licences are in `Resources/Highlight/`, and
`Sources/Honeycode/Vendor/Highlightr/README.md` records the three deliberate
changes from upstream.

---

## A note on the bundle identifier

It's `com.matthewquigley.honeycode`, and it is load-bearing in three places: the
preference domain shared by the app and `ai`, the Keychain service holding
custom-account API keys, and the code-signing requirement.

Saved sessions and artifacts are **not** among them — those live under
`~/Library/Application Support/Honeycode/`, which is named literally and doesn't
move. So changing the identifier costs an already-used machine its preferences
and its stored API keys, plus one more round of Documents/Desktop prompts. A
machine that has never run it pays nothing at all.

If you fork this properly and want your own identifier, change every one of
these together, before anyone on your team has run it rather than after:

```sh
grep -rn com.matthewquigley.honeycode --include='*.swift' --include='*.sh' --include='*.plist' .
```

That is `Resources/Info.plist`, `Sources/AgentKit/Prefs.swift` (the preference
domain), `Sources/AgentKit/CustomAccount.swift` (the Keychain service — miss this
one and saved API keys become unreadable), `build.sh`, `tools/doctor.sh` and
`tools/signing-identity.sh`. The two `DispatchQueue` labels are cosmetic.

---

## Licence

None, deliberately — all rights reserved.

This is an internal tool, shared privately with the team that uses it. If you
have access to this repo you're meant to clone it, build it and use it; that
access is the permission. It carries no open-source licence and isn't for
redistribution outside the team.

If that ever needs to change — going public, or an employer wanting clarity on
who owns what — add a real licence at that point rather than assuming this note
covers it.
