# Plugin system: design

Status: **proposal**. Nothing implemented. This document decides the
shape; implementation phases at the end.

## The one-sentence version

Plugins are out-of-process MCP servers (tools) plus a tiny 3code-native
event stream (hooks), with every model-facing surface mounted lazily so
the per-request schema only grows when a plugin is actually used. Idle
plugins cost zero tokens.

## What already exists (and why a plugin system is still missing)

3code has three extension seams today:

- **Closure hooks** (`api.nim`): `VerifyProfileHook`, `BearerHook`,
  `ExtraHeadersHook`, `ApiStreamHooks`. Internal, compile-time, used by
  the auth modules. Not user-extensible.
- **Skills** (`prompts.nim` `discoverSkills`): markdown files from
  `.3code/skills`, `.agents/skills`, user config dir, built-in dir.
  Listed as a compact catalog in the system prompt, `cat`-ed by the model
  on demand. This is already the right *economics* pattern (zero cost
  until loaded) but it only extends knowledge, not capability.
- **Config** (`config.nim`): `[provider]`, `[settings]`, `[search]`,
  `[shortcuts]`. Static data, no code.

What none of these give you: new tools the model can call, lifecycle
observability, third-party auth, policy enforcement at tool time. That
is what plugins are for.

## Non-negotiable constraints (these decide everything)

1. **Token economy is the product.** A plugin system that appends N tools'
   JSON schemas to every request is a denial-of-wallet attack on 3code's
   core promise. Claude Code with 5 MCP servers pays ~2-4k schema tokens
   on every single call. We cannot ship that. Consequence: tool schemas
   are **mounted on demand**, never blanket-advertised.
2. **The TUI process must not crash, ever.** The rendering engine is the
   most bug-dense code we own (see AGENTS.md, bug-hall-of-fame.md).
   Plugin code must never run in-process. Consequence: plugins are
   subprocesses, unconditionally. No `dynlib`, no Nim-script eval.
3. **Language-agnostic.** Free-tier users have Python, Node, a shell.
   Plugins must be trivially writable in anything. Consequence: the wire
   protocol is line-delimited JSON over stdio, nothing more exotic.
4. **The sandbox story must stay coherent.** The agent (model) is
   untrusted and fenced. Plugins are software the *user* installed, same
   trust level as 3code itself. Consequence: plugins run unfenced, but
   the model can only reach them through the dispatch layer, and the
   agent itself must never be able to install or enable plugins.
5. **Windows/macOS/Termux parity.** stdio subprocesses work everywhere
   we ship. No sockets, no unix-only tricks in v1.

## Layer 1: tools, via MCP

**Decision: adopt MCP (Model Context Protocol) as the tool protocol.**

Not a bespoke protocol. The reasoning is blunt:

- The MCP ecosystem already exists. Hundreds of servers (GitHub,
  Postgres, Playwright, Linear, Sentry, filesystem gateways...). A small
  agent building a bespoke protocol gets zero third-party plugins
  forever; one speaking the MCP subset gets the whole corpus on day one.
- 3code already speaks MCP-shaped JSON-RPC for web search (`web.nim`:
  the exa and parallel backends are MCP endpoints, `tools/call` over
  HTTP). The wire shape is not foreign to the codebase.
- We implement a **subset**: `initialize`, `tools/list`, `tools/call`.
  We ignore `resources`, `prompts`, `roots`, and explicitly refuse
  `sampling` (see "What we deliberately do not expose").

But MCP is *transport*, not economics. The 3code layer on top is the
mount system:

### Mounting

Plugins with tools are listed in the system prompt as one catalog line
each (same shape as the skills catalog):

```
Plugins (idle): github (GitHub issues/PRs), sqlite (query ./app.db), approve (ask the human)
To load a plugin's tools, call `plugin {load: "<name>"}`.
```

When the model calls `plugin {load: "github"}`:

1. 3code spawns the plugin (if not already running), performs the MCP
   handshake, caches `tools/list`.
2. The plugin's tool schemas are merged into the wire tool schema as an
   overlay on the family's base schema, from that model call onward.
3. The tool result confirms compactly:
   `loaded github: get_issue, list_prs, create_comment (+412 schema tokens)`.
4. Dispatch: `actions.nim`'s unknown-tool catch-all consults mounted
   plugin tools before erroring. A mounted tool call goes out as
   `tools/call`, result text comes back capped and truncated like web
   results (default 20k chars, manifest can lower it).

Cost profile: idle plugin = 1 catalog line (~15 tokens). Mounted plugin
= its schema size, once, for the rest of the session. This mirrors the
skills philosophy exactly: list cheap, load on demand.

**Cache interaction (important).** Mounting changes the tool schema,
which busts the prompt cache prefix for the next call. That is one cache
break per plugin per session, not per call, and the mount point is where
the user's task already demanded it. The alternative (schemas always in
the prefix) pays on every call. Document it, don't fight it.

**User control.** Config keys:

```
[plugins]
off = "github"          ; never listed, never mountable
mount = "auto"          ; auto | ask | never
                            auto: model mounts freely (default)
                            ask: TUI prompt on first mount per session
                            never: catalog hidden from the model entirely
```

`:plugin` in the TUI lists plugins with live status (running, mounted,
sick) and toggles.

**Description dieting.** MCP tool descriptions in the wild are often
500-character essays. A plugin manifest may override descriptions:

```
[tool.create_comment]
desc = "Comment on a GitHub PR/issue."
```

The mount path sends the overridden one-liner on the wire. This is the
3code house style applied to someone else's schema, and it routinely
halves mounted cost.

## Layer 2: hooks, 3code-native

MCP deliberately has no lifecycle events. We need them, so we define a
small event stream, pushed as JSON lines to the plugin's stdin (same
process as Layer 1; a plugin may be tools-only, hooks-only, or both,
per its manifest).

Events (v1):

| event | payload | sync? |
|---|---|---|
| `session.start` | cwd, provider, model, session path | no |
| `turn.start` | turn number, prompt token estimate | no |
| `turn.end` | `Usage` record, wall time | no |
| `tool.pre` | tool name, args, working dir | **yes** |
| `tool.post` | tool name, result digest (size, exit code, first 200 chars), duration | no |
| `file.write` | path, bytes (fires for write/patch/apply) | no |

`tool.pre` is the only synchronous hook and the whole reason the layer
exists. A plugin has 2 seconds to reply with one of:

- `{"allow": true}` or silence (timeout = allow; a hung hook may never
  block the agent)
- `{"allow": false, "message": "PATH is in .git, refusing"}` (veto: the
  tool result carries the message, prefixed `plugin <name>: ...` so the
  model sees provenance and can adapt)
- `{"rewrite": {<new args>}}` (e.g. inject `--no-color`, force a
  timeout, redact a secret)

Fire-and-forget events never block the loop: written to the pipe and
forgotten. A plugin whose pipe is full gets dropped from notification
for the session (it is too slow to be a hook), never blocks.

**Plugin state.** Hooks see every tool call, including calls to MCP
tools (Layer 1) and to native tools. A hook plugin can veto a
`sqlite_exec` from an MCP plugin. This composition (policy plugin
watches capability plugin) is where the design earns its keep; see
"Conceived plugins" below.

## Layer 3: auth plugins

The internal closure hooks (`BearerHook`, `ExtraHeadersHook`) exist
because OAuth flows can't be expressed as static config. Externalize
the narrow case: a manifest `type = "auth"` plugin is an executable
that, when run with a profile name, prints a fresh bearer token to
stdout (plus optional header lines). 3code caches per its declared TTL
and installs it as that provider's `BearerHook`. This lets a new
subscription provider ship as a plugin instead of a fork. ~30 lines of
contract, no MCP involved. v1.5, after tools and hooks prove the
subprocess machinery.

## Layer 4: skills bundling

A plugin manifest may name a `skills/` directory; its markdown files
join `skillsDirs()` search path (project plugins' skills shadow
user-level, matching existing precedence). Trivial to implement, ships
with Layer 1, and means a plugin can carry its own usage knowledge
("how to query this database well") instead of bloated tool
descriptions. This is the correct place for plugin prose: skills are
loaded on demand by the model, priced per use.

## What we deliberately do not expose

Each refusal is a decision, not an omission:

- **Message-list mutation.** Plugins never see or edit the conversation
  array. It would break per-family prompt discipline, bust caches, and
  make prompt injection a plugin API. Hooks observe tool I/O, not chat.
- **UI internals.** No drawing, no layout, no footer access. The engine
  is fragile by admission (hall of fame). v2 may allow one bar text
  segment through a single vetted setter, experimental-gated. Not v1.
- **MCP `sampling`** (plugin asks the model to run inference). A cost
  hole and a loop risk. Refused on handshake.
- **In-process anything.** No dynlib, no eval, no scripts run inside
  the TUI. One exception already exists: config `[shortcuts]` remaps
  editor keys, which is data, not code.
- **Plugin installation by the agent.** The model can never write
  `~/.config/3code/plugins` (the default `.sandbox` policy should deny
  writes there explicitly, plugin system or not). Installing a plugin
  is a human action.

## Discovery, manifests, trust

Layout mirrors the skills pattern:

```
~/.config/3code/plugins/<name>/plugin.toml   user-installed, enabled
.3code/plugins/<name>/plugin.toml            project-shipped
```

Manifest:

```
# plugin.toml
name = "github"
version = "1.2.0"
type = "mcp+hooks"          ; mcp | hooks | auth, combinable
command = ["python3", "server.py"]
description = "GitHub issues/PRs"     ; one catalog line, enforced short
cap = 20000                 ; max tool-result chars (default)
timeout = 30                ; per-call seconds, clamped like bash

[events]                    ; hooks this plugin subscribes to
listen = ["tool.pre", "tool.post"]

[tool.create_comment]       ; description overrides (the diet)
desc = "Comment on a GitHub PR/issue."
```

Trust model, stated plainly in `:plugin help`: installing a plugin is
installing software; it runs with your permissions, unsandboxed, like
3code itself. The fences protect you from the *model*, not from your
own installs.

**Project plugins start disabled.** A cloned repo may ship
`.3code/plugins/`; on first sight the TUI prints one line ("this
project ships 2 plugins; `:plugin on` to enable") and remembers the
answer in the *user* config, never in the repo. This closes the
prompt-injection-shaped hole (malicious repo + eager model = exfil
service) the same way `.sandbox` closes path holes.

Lifecycle: lazy spawn at first use (startup stays fast), one silent
restart on crash, then marked sick for the session with a clean tool
error naming the plugin. Stderr from a plugin goes to the debug log,
never the transcript.

## Why this shape (summary of decisions and their reasons)

| decision | reason |
|---|---|
| subprocess, never in-process | TUI crash isolation, sandbox coherence, language freedom |
| MCP subset for tools | ecosystem leverage; bespoke protocols get zero plugins |
| mount-on-demand schemas | token economy is the product; skills proved the pattern |
| native event stream for hooks | MCP has no lifecycle; we need `tool.pre` veto |
| one sync hook only (`tool.pre`) | hooks on the hot path would add latency to every tool call |
| project plugins disabled by default | repo-shipped code must not auto-run |
| auth as tiny stdout contract | OAuth needs code, not config; narrowest possible surface |
| refuse sampling/resources | cost holes and prompt-discipline breaks |

## Conceived plugins

Each exercises a different part of the surface.

**`github` (mcp).** The canonical mount example. Idle cost: one catalog
line. The interesting detail is the diet: the stock MCP GitHub server's
schema is ~2.8k tokens; curated overrides bring it under 900. Mounted
once when you actually say "look at issue 43", amortized over the
session.

**`lintgate` (hooks).** `tool.pre` on write/patch: runs the project's
formatter, vetoes the write with the diff of what it *would* have
changed ("plugin lintgate: prettier reformat required, 3 lines"). The
model self-corrects on the next call instead of shipping
badly-formatted code. Zero model-facing surface, zero catalog tokens;
pure harness-side value. This is the poster child for why hooks are
worth a layer.

**`secretkeeper` (hooks).** `tool.post` scan of every tool result for
API-key-shaped strings (AWS, ghp_, sk-, PEM blocks); matches replaced
with `[redacted:aws-key]` before the result enters context. Doubly
3code: saves tokens AND stops secrets riding to the provider in tool
output. Observes bash, read, and MCP tools alike.

**`dbguard` (hooks, composing with mcp).** You mount `sqlite-mcp` so
the model can query a database; `dbguard` watches `tool.pre` for its
`exec` tool, parses the SQL, vetoes anything `DELETE`/`DROP`-shaped
outside an explicit `--yes-destructive` session flag. Policy plugin
guarding capability plugin, no cooperation needed between them.

**`approve` (mcp).** Registers one tool, `ask_human(question, options)`.
When the model calls it, 3code surfaces a y/n/choice prompt in the
editor line; the human's answer returns as the tool result. A plugin
whose backend is *you*. Gives cautious users a middle path between
"full auto" and "ask before every command": destructive work becomes
opt-in through the prompt itself.

**`tokenmeter` (hooks).** `turn.end` appends the `Usage` record to
`~/.local/share/3code/usage.csv`; `:plugin stats` reads back
per-provider, per-model totals for the month. Free-tier users are
exactly the people obsessing over quota ceilings; nobody in the
ecosystem gives them a local, provider-agnostic ledger.

**`patient-notify` (hooks).** Pairs with 3code's ~36h patient retry:
listens to a new `model.retry` event (trivial to add: fired on 429/5xx
backoff) and desktop-notifies "holding for quota reset, next attempt in
14m" so a parked session on a free tier is legible from across the
room.

**`hands-off-auth` (auth).** A new subscription provider's login is a
browser dance and a device-code poll. Ships as an auth plugin printing
bearer tokens; users of that provider install one directory instead of
waiting for a 3code release.

**`testwise` (hooks, with state).** `tool.post` on bash watches test
commands, keeps a sqlite of (file, error signature) outcomes across
sessions. When the model hits a failure whose signature keeps flapping,
the hook rewrites... no: it vetoes nothing, but the plugin can expose a
*skill* (Layer 4) telling the model how to query its own log with a
plain `cat`-able file, e.g. "3 failures of this test today, three
different errors: treat as flaky, one more run before you refactor."
Harness memory that survives `:clear`.

## Implementation sketch

Phased, each phase independently shippable:

1. **Registry + skills bundling** (~250 loc). Manifest parse, discovery
   dirs, `:plugin` TUI listing, disabled-by-default project gating,
   plugin skills in `skillsDirs()`. Value before any protocol exists.
2. **MCP client + mount** (~600 loc). `plugins.nim`: lazy spawn,
   handshake, `tools/list`, `tools/call`, timeout/crash policy; the
   `{{plugins}}` catalog line in `prompts.nim`; the `plugin {load}`
   harness tool; schema overlay in `toolsFor`; dispatch hook in
   `actions.nim` `unknownTool` path. Fixture plugin in `testdata/`
   (shell or Nim) + tests wired into the shakedown per testing.md.
3. **Hooks** (~300 loc). Event pump, sync `tool.pre` with 2s budget,
   `tool.post`/`turn.end` fire-and-forget, sick-plugin demotion.
4. **Auth plugins** (~80 loc) and, experimental-gated, one bar text
   segment setter.

Open questions, deliberately deferred: result streaming for long tool
calls (v2, alongside whatever streamexec needs), hook plugins that want
to *inject* a tool result augmentation on `tool.post` (write-amplitude:
probably yes in v2 with the same 2s budget), remote MCP over HTTP (the
search backends prove the shape; security review first).
