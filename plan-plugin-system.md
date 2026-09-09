# Plugin system: design (rev 5, operative)

Status: **decided scope**. This revision folds the final calls: no
dynamic loading (one binary, in-tree source plugins only), no auth
plugins (vendor auth stays compiled-in core), model-facing capabilities
are command-line tools, and 3code maintains an official list of CLIs
that work well with it. Earlier revisions (C-ABI `.so` tier, auth
layer, mounting) are superseded; the decision trail lives in
`plan-vim-lesson.md`, `plan-prior-art-dsh.md`, and
`plan-evaluation-pi-5000.md`.

## The one-sentence version

Capabilities are CLI tools documented by skills (mass-produced from MCP
by `mcpwrap`, curated by an official tools list); the harness is
extended by **in-tree Nim plugin modules compiled into the one binary**
(soft UX and policy gates only); idle plugins cost zero tokens, by law.

## The economy invariant (the governing law)

**An installed but idle plugin may not add any recurring token cost,
and no plugin API anywhere may add recurring model-visible cost.
Model-visible text enters only through usage-priced channels: tool
results the model chose to invoke, files it chose to read.**

The reasoning is incentive economics. Every agent plugin ecosystem
splurges (pi's `registerTool` schemas per call, dsh's schema assembly,
Claude Code's MCP prefixes) because plugin authors pay nothing for the
user's context: visibility is free to the author, billed to the user.
The only durable fix is architectural: do not ship the spending API.

What survives the law:

| class | touches | token cost | examples |
|---|---|---|---|
| **soft** | human surface: commands, keys, bar, transcript, askUser | zero | tokenmeter, `:session pick`, a cow as your welcome banner |
| **policy** | tool gates: veto/rewrite/redact | zero or negative | lintgate, approve, secretkeeper, dbguard |
| **text** | skills + CLIs, opt-in per use | usage-priced | mcpwrap, github-cli, the official list |

Vendor auth stays compiled-in core exactly as it is (the OAuth modules
ship faster than other tools already; that velocity is the feature).
The pitch line: plugins can make 3code cheaper, safer, or nicer to
drive, never bigger.

## Layer 1: capabilities = CLI tools + skills + the official list

**3code never speaks MCP. No schema mounting, no MCP client, no
`tools/call` from the harness, ever.** The model's tool surface stays
frozen (`bash`, `read`, `write`, `patch`, `web_search`, `web_fetch`,
`update_plan`); new capabilities are commands the model drives through
bash and learns from skills.

Token math, per 30-call session with the capability used:

| approach | per-call cost | one-time | session total |
|---|---|---|---|
| raw MCP schema mount | ~2,800 tok | (none) | ~84,000 tok |
| curated schema mount | ~900 tok | (none) | ~27,000 tok |
| CLI + generated skill | ~15 tok (catalog line) | ~400 tok (skill `cat`) | ~850 tok |

32x to 99x cheaper; the "26x" headline is the floor. Qualitatively
better too: models have deep training on shell usage and none on niche
MCP schemas; commands compose (pipes, grep); output flows through the
existing sandbox and bash caps. A mounted MCP tool escapes `.sandbox`
by construction; a wrapped CLI never can.

### `mcpwrap`

A standalone Nim tool (shipped alongside 3code, useful to any agent):
a minimal stdio MCP client (`initialize`, `tools/list`, `tools/call`)
that turns any MCP server into a normal CLI plus a generated skill.

```
mcpwrap add github -- npx -y @modelcontextprotocol/server-github
mcpwrap github list_prs --repo capocasa/3code --state open
mcpwrap skill github > ~/.config/3code/skills/github-cli.md
```

- Per-call spawn in v1; a `mcpwrapd` daemon is a later optimization.
- `tools/list` cached under `~/.local/share/3code/mcp/<name>/`.
- The diet happens in the skill, not the schema: generated skills are
  one command line per tool plus flags, hand-editable; regeneration
  writes `.new` instead of clobbering.
- Output is text, capped like web results (`--max-chars`, default 20k).

### The official tools list

A curated, versioned page (`docs/tools.md`, linked from the README):
command-line tools that work *well* with 3code, each with a shipped
built-in skill. Seed set: `rg`, `gh`, `jq`, `git`, `sqlite3`, `curl`.
Admission criteria are 3code-flavored, not generic:

- economical output by default (quiet flags, concise modes, no color
  noise; the skill encodes the cheap incantations),
- non-interactive, stable exit codes, fast startup,
- text out, composable with pipes.

This replaces the registry ambition from earlier revisions: no plugin
marketplace, no 5000-package swamp. One curated list of economy-grade
CLIs, plus `mcpwrap` to bridge anything missing. Success metric: every
entry earns its place the same way everything else earns its tokens.

### `3code tool add`: the installer for the list

**Decision: included in the one binary, as `3code tool add <name>`,
implemented as a thin dispatcher over the system package manager**, not
as a package manager. Three rules keep it from becoming the bloat you
feared:

1. **Dispatcher, not manager.** It knows, per tool per platform, the
   package id and the silent flags (winget `BurntSushi.ripgrep.MSVC`,
   brew/apt `ripgrep`, pkg `ripgrep`, ...), detects the manager in
   order (winget, scoop, choco / brew / apt, dnf, pacman / pkg), execs
   it, and prints the manual command when no manager exists. No
   version pinning, no mirrors, no dependency resolution, no checksums
   (the manager's job). Updates: tell the user to use their manager.
2. **One data source.** The same table drives `docs/tools.md`,
   `3code tool list`, and the install path. The table *is* the
   curation; the command is exec over it.
3. **User-run only.** Installing software is a human action; default
   sandbox policy denies `3code tool add` from the agent's bash.

Estimated cost: ~300-400 loc, which buys the Windows crowd
`3code tool add rg gh jq` instead of package-name archaeology across
winget/scoop/choco. Bloat tripwire: the day it needs pinning, mirrors,
or its own update path is the day it becomes a separate tool. A
separate binary now would fragment the official list's data and hand
the audience least equipped to install things (Windows, first day) a
second installer. Naming: `tool`, not bare `add`, because `add` alone
is ambiguous (`:provider add` exists in-app) and `3code tool` groups
`list`/`doctor` later, matching the `3code wall setup-windows`
subcommand pattern. After install it prints the tool's built-in skill
path so the loop from list, to install, to agent-usable closes in one
command.

## Layer 2: the harness = in-tree Nim plugins, one binary

**Plugins are Nim modules in `plugins/` in the 3code repo, compiled
into the binary.** No dynlib, no C-ABI, no manifests, no load-time
trust decisions: plugin code is core code, reviewed like core, broken
like core (compile errors), and shipped in the one static binary.
Internal APIs are unstable by policy; the compiler, not a version
check, tells contributors what churned. This is the Linux in-tree
driver model: plugins socially, monolith technically.

The contribution process is the feature: PR a plugin, an AI reviews
(3code reviewing 3code plugins, dog food), the maintainer merges on
pass. Pronto. The review checklist is short because the invariant
already did the hard work: does it touch the model surface (reject),
is it fast and thread-safe on the hook paths, does it earn its place.

### The plugin API

A plain Nim module, `plugin/api.nim`; no macros, registration is
ordinary procs at init:

```nim
import threecode/plugin/api

proc init*(h: PluginHost) =
  h.on "tool.pre", proc (e: ToolEvent): ToolVerdict =
    if e.name in ["write", "patch"]:
      let fixed = format(e.path, e.body)
      if fixed != e.body:
        return veto("plugin lintgate: reformat required, 3 lines")
    allow()

  h.on "turn.end", proc (e: TurnEvent) = discard e.usage.appendLedger()

  h.command "usage", "monthly token totals", proc (args: string) =
    h.emit usageCard(monthTotals())

  h.bar proc (): string = "◎ " & goalText() & " " & planProgress()

  h.bindKey "CtrlT", "usage"

  h.ask   # declares use of the synchronous user-prompt service
```

Host services (the whole surface, deliberately narrow; the vim lesson
chose these): `emit` (append-only transcript block), `bar` (status
line segment), `askUser` (sync y/n/choice in the editor line, this is
`vim.ui.select`), `command` (`:` registration with completion),
`bindKey` (the same table `[shortcuts]` loads), `post` + `setTimer`
(async, thread-safe back into the pump), `lastResult`/`usage`/
`sessions` (read services), `queuePrompt` (feed the existing queued
user drain in `turns.nim`; visible in the transcript, Esc cancels,
rate-limited).

### Events (v1)

| event | payload | sync? |
|---|---|---|
| `session.start` | cwd, provider, model, session path | no |
| `turn.start` / `turn.end` | turn no; `Usage` + wall time | no |
| `model.retry` | provider error, backoff seconds | no |
| `tool.pre` | tool name, args | **yes** |
| `tool.post` | name, exit/size digest, duration | no |
| `file.write` | path, bytes (write/patch/apply) | no |

`tool.pre` is the only synchronous gate: 2s budget, silence = allow,
veto = tool result prefixed `plugin <name>: ...`, rewrite = replace
args. Multiple listeners run in registration order; a veto
short-circuits and names the plugin (the dsh waterfall lesson).
Callbacks fire on the turn loop thread (`tool.*`) or netthread
(`model.*`): be fast, be thread-safe.

Async events are fire-and-forget. A slow plugin on a sync path is
demoted for the session after repeated timeouts; being in-tree, a
*crashing* plugin is just a bug we fix, which is the entire point of
one binary.

## Layer 3: skills (unchanged)

Skills load from `.3code/skills`, `.agents/skills`, the user config
dir, and the built-in dir; one catalog line each; `cat`-ed on demand.
`mcpwrap skill` generates them; the official list ships them for its
entries. The built-in catalog stays lean (the invariant applies to us
too): every line earns its place.

## What we deliberately do not expose

- **MCP in the model path** (no client, no schemas, no mounting).
- **New model-facing tools from plugins.** Capabilities are commands.
- **Message-list mutation.** Plugins never see the conversation array.
- **Recurring model-visible cost of any kind** (the invariant).
- **UI internals.** `emit`, `bar`, and `askUser` are the entire UI
  surface: everything a plugin shows is text in the transcript, the
  vim bet that one medium beats N APIs.
- **Dynamic loading, ever.** One binary. If a plugin matters, it
  upstreams; if it cannot, it ships as a CLI + skill instead.

## Trust model (now one line)

All plugin code is reviewed core code in one binary. The untrusted
surfaces are exactly the ones already fenced: CLIs run through the
sandboxed bash under `.sandbox`, and skills, which are text. The model
can never write config or plugin source (default sandbox deny rule).

## Conceived plugins (final list)

- `lintgate` (policy): format-on-write veto; 90% also available as the
  `formatter = "..."` setting, the `'formatprg'` analog.
- `approve` (policy + soft): sync y/n in the editor line before
  destructive bash. The demo of why in-process sync hooks matter.
- `secretkeeper` (policy): strip key-shaped strings from every tool
  result. Negative token cost.
- `dbguard` (policy): veto destructive SQL against the project DB CLI.
- `tokenmeter` (soft): usage ledger, live bar segment, `:usage` card.
- `goalkeeper` (soft + policy + text): the worked example below.
- `testwise` (soft + text): cross-session flaky-test log plus a bundled
  skill telling the model to consult it.
- A cow as your welcome banner (soft): `emit` at `session.start`.
  Zero cost means zero cost; go for it.

## Worked example: `:goal` mode

The stress test, unchanged in shape, now as an in-tree plugin.

State is a file, not an API: `~/.local/share/3code/goal/<session>`
(objective line, notes, `DONE: <summary>`). The filesystem is the
model↔plugin channel: the model reads it with the native `read` tool,
completes it with the native `write` tool. The goal survives `:clear`
and restarts because it lives outside the context, which is the point.

Human side: `h.command "goal"`, `h.bar` shows `◎ fix flicker · 3/5`,
`emit` prints a goal card on set/complete. Model side: a bundled skill
(`goal-mode.md`) teaches "while the goal file exists, read it first
each turn, align `update_plan`, write `DONE:` when met": one ~60-token
read per turn, only while active, usage-priced. Progress comes from
`tool.pre` on `update_plan` (passive). Completion: the `file.write`
event on the goal file triggers `askUser` "mark goal done?"; the
human, not a heuristic, closes a goal.

Auto-continue uses `queuePrompt` ("[goal] continue") through the
existing queued-user drain: visible in the transcript, Esc cancels,
rate-limited, `askUser` checkpoint every K turns. Plugins never
sleep-walk the agent; they queue visible input.

## Implementation sketch

1. **Plugin substrate** (~450 loc): `plugin/api.nim`, the `PluginHost`
   registrar, event pump wired into `turns.nim`/`actions.nim` at six
   call sites, `:` command dispatch, the host services. No loader, no
   ABI check, no crash markers: none are needed in-tree.
2. **First-party tree**: `plugins/lintgate.nim` (reference
   implementation and test fixture), then `tokenmeter`, `approve`,
   `goalkeeper`.
3. **`mcpwrap`** (~700 loc, standalone): stdio MCP client, `add`/
   `skill`, tools.json cache, flag mapping, text output with caps.
4. **The official list**: `docs/tools.md` with the seed set and
   admission criteria, plus built-in skills for each entry.
5. **Settings discipline**: `formatter = "..."` (`'formatprg'` analog)
   and the `path:line:col:` issue-line convention for plugin messages
   (the quickfix analog: textual now, navigable later).

Visual tests per `.agents/testing.md` cover the `askUser` editor-line
prompt, the bar segment, and emitted transcript blocks; the rest is
headless testament. Deferred: `mcpwrapd` daemon, more UI setters,
subagents-as-a-seam (study dsh's provider range when it comes up).
