# Plugin system: design, revision 2

Status: **proposal**, revised after review. Deltas from revision 1: no
MCP anywhere in 3code (a Nim framework wraps MCP servers into plain CLI
tools instead), and harness plugins are **in-process** via a versioned
C-ABI. Both changes are decisions, not suggestions. Revision 3 folds in
the vim/neovim lesson (see `plan-vim-lesson.md`): command registration,
transcript emission, async post + timers, read services, keymap
registration.

## The one-sentence version

Capabilities are extended with **CLI tools documented by skills**
(zero schema tokens, produced in bulk by a new Nim framework that wraps
MCP servers into commands); the harness is extended with **in-process
Nim plugins** loaded from shared libraries through a small versioned
ABI. 3code itself never speaks MCP and never mounts tool schemas.

## Point of departure: the model-facing surface is already complete

3code's tool surface for the model is `bash`, `read`, `write`,
`patch`, `web_search`, `web_fetch`, `update_plan`. Its knowledge surface
is skills: a one-line-per-file catalog in the system prompt, `cat`-ed by
the model on demand. Together these already form a complete capability
extension mechanism: any executable plus a skill is a plugin the model
can use, today, with no core changes.

```
- ~/.local/share/3code/skills/github-cli.md
```

That catalog line is the *entire* recurring token cost. So the plan for
capabilities is not to build a mechanism into 3code; it is to
mass-produce CLIs + skills from the one ecosystem that already has
hundreds of them (MCP), without letting MCP itself into the agent loop.

## Layer 1: capabilities: CLI tools + skills, produced by `mcpwrap`

**Decision: 3code never speaks MCP. No schema mounting, no MCP client,
no `tools/call` from the harness, ever.** Instead, a new Nim framework,
`mcpwrap`, turns any MCP server into a normal command-line tool. The
model then uses that tool through `bash`, exactly like `git` or `rg`,
and learns it from a generated skill.

### The token math (why this is ~26x cheaper, minimum)

An MCP tool schema is paid on *every* model call while mounted. A CLI is
paid as one catalog line per call plus a one-time skill read.

| approach | per-call cost | one-time | 30-call session, plugin used |
|---|---|---|---|
| raw MCP schema mount | ~2,800 tok | (none) | ~84,000 tok |
| curated schema mount | ~900 tok | (none) | ~27,000 tok |
| CLI + generated skill | ~15 tok (catalog line) | ~400 tok (skill `cat`) | ~850 tok |

27,000 / 850 is 32x; 84,000 / 850 is 99x; prompt-cache discounts apply
to both sides and preserve the ratio. The "26x" headline is the
conservative floor of this table. And when the plugin is *not* used in
a session, the CLI costs its 15-token line while the mounted schema
costs its 900 tokens anyway.

Qualitatively, not just cheaper: models have deep training coverage of
shell usage and near-zero coverage of niche MCP tool schemas; commands
compose (`mcpwrap gh list-prs | jq ...`, grep, redirect); results are
plain text already capped by the existing bash output limits.

### What `mcpwrap` is

A standalone Nim binary (shipped alongside 3code, useful to any agent).
It contains a minimal MCP client (stdio JSON-RPC: `initialize`,
`tools/list`, `tools/call`) and exposes wrapped servers as subcommands:

```
# register a server (records the command; fetches nothing)
mcpwrap add github -- npx -y @modelcontextprotocol/server-github

# use it: each MCP tool becomes a subcommand, schema properties become flags
mcpwrap github list_prs --repo capocasa/3code --state open
mcpwrap github get_issue --number 43

# generate the skill (one line per tool, flags from the schema)
mcpwrap skill github > ~/.config/3code/skills/github-cli.md
```

Design points:

- **Per-call spawn in v1**: each invocation runs the MCP server, does
  the handshake, calls one tool, exits. Simple, no daemons, works on
  Termux. Slow for npx-class servers (~2s); a `mcpwrapd` daemon holding
  hot servers is the v2 optimization, behind the same CLI surface.
- **`tools/list` is cached** (`~/.local/share/3code/mcp/<name>/`),
  so usage is instant and `mcpwrap skill` works offline.
- **The diet happens in the skill, not the schema.** Generated skills
  are one command line per tool plus a flag summary, editable by hand;
  regeneration writes `.new` rather than clobbering user edits. Curating
  a bloated 500-char MCP description into a one-liner now costs zero
  per-call tokens.
- **Output is text**, not JSON: tool results print as-is (most MCP
  tools return markdown/text blobs), JSON results pretty-compact, a
  `--max-chars N` cap defaults to the same 20k budget as web results.
- Non-MCP tools need no framework at all: `gh`, `sqlite3`, `jq` plus a
  hand-written skill are first-class plugins by the same definition.

## Layer 2: the harness: in-process Nim plugins

**Decision: plugins run inside the 3code process, loaded from shared
libraries (`.so`/`.dll`) through a versioned C-ABI.** This is critical,
and it is achievable safely in Nim if the boundary is disciplined. The
rules that make it work:

1. **Only C types cross the boundary.** No Nim objects, no GC refs, no
   seqs. Strings cross as `(cstring, len)` or JSON, always copied.
2. **Each side owns its heap.** The plugin is a full Nim compilation
   with its own allocator. The host hands the plugin an
   allocate/deallocate pair for return values, so the host can free
   them. GC pointers never cross.
3. **One flat vtable, versioned.** The plugin exports a single
   `threecode_plugin_init` returning a vtable struct; the host checks
   `abiVersion` and refuses mismatches with a clear error.
4. **Errors cross as values.** Catchable plugin errors return a code +
   message; the host logs and demotes the plugin. (A hard segfault
   still kills the TUI; see the crash guard.)

### The ABI sketch

```nim
# threecode/plugin/api.nim - the SDK plugins compile against
type
  HostServices* {.bycopy.} = object
    abiVersion*: cint
    alloc*: proc (n: csize_t): pointer {.cdecl.}
    dealloc*: proc (p: pointer) {.cdecl.}
    setBarText*: proc (s: cstring) {.cdecl.}
      ## A text segment in the status bar (the statusline lineage).
    askUser*: proc (question, options: cstring,
                    outBuf: cstring, outCap: cint): cint {.cdecl.}
      ## Synchronous y/n/choice prompt in the editor line. Returns the
      ## chosen index (1-based) or 0 on timeout/ctrl-c.
      ## This is vim.ui.select.
    emitTranscript*: proc (s, kind: cstring) {.cdecl.}
      ## Append a committed scrollback block. The "everything is a
      ## buffer" primitive: any plugin output becomes a receipt,
      ## styled by the engine, append-only per .agents/design.md.
    post*: proc (ev, payloadJson: cstring) {.cdecl.}
      ## Thread-safe; delivered on the next event-pump tick. The async
      ## escape hatch (neovim's lesson: never block, post instead).
    setTimer*: proc (ms: cint, ev, payloadJson: cstring) {.cdecl.}
    registerCommand*: proc (name, argSpec: cstring) {.cdecl.}
      ## The `:` command layer (fugitive's home). Dispatched back as an
      ## onEvent "cmd.<name>" with the raw args as payload; argSpec is
      ## a completion spec the command-line parser uses.
    lastResult*: proc (what, outBuf: cstring, outCap: cint): cint {.cdecl.}
      ## Read services: "lastResult" (previous tool receipt), "usage"
      ## (running totals), "sessions". Read-only host state.
    bindKey*: proc (keys, cmd: cstring) {.cdecl.}
      ## Writes the same table `[shortcuts]` loads at startup; plugins
      ## get no separate input mechanism, just a shared one.

  PluginVtable* {.bycopy.} = object
    abiVersion*: cint
    name*: cstring
    onEvent*: proc (ev: cstring, payloadJson: cstring,
                    outJson: cstring, outCap: cint): cint {.cdecl.}
      ## Returns: 0 = no-op, 1 = veto (outJson carries the reason),
      ## 2 = rewrite (outJson carries new args)

  InitFn* = proc (host: ptr HostServices): ptr PluginVtable {.cdecl.}
```

Events ride one entry point as `(name, JSON payload)`, which keeps the
vtable flat and lets new events ship without ABI churn. The SDK wraps
this in Nim ergonomics (`onEvent "tool.pre": ...` sugar via plain
proc assignment; no macros).

### Event set (v1)

| event | payload | sync? | fired from |
|---|---|---|---|
| `session.start` | cwd, provider, model, session path | no | main |
| `turn.start` / `turn.end` | turn no; `Usage` record + wall time | no | main |
| `model.retry` | provider error, backoff seconds | no | netthread |
| `tool.pre` | tool name, args JSON | **yes** | turn loop |
| `tool.post` | name, exit/size digest, duration | no | turn loop |
| `file.write` | path, bytes (write/patch/apply) | no | turn loop |

`tool.pre` keeps the 2s budget from revision 1: silence or timeout =
allow, veto = tool result prefixed `plugin <name>: ...`, rewrite =
replace args. Being in-process, a sync hook can now do what
out-of-process never could: **call `askUser` and block on the human**
while the harness pumps the input loop. That single capability is worth
the whole ABI (see `approve` below).

Threading: callbacks must be thread-safe; `tool.*` fire on the turn
loop thread, `model.*` and auth on the netthread, and all must return
fast. Plugins that need slow work keep their own thread and surface
results on a later event.

### Crash guard (the honest cost of in-process)

A plugin segfault takes the TUI with it. Mitigations, browser-style:

- On load, 3code writes `plugins/<name>.loaded`; cleared on clean exit.
  A stale marker at startup means the last session died with that
  plugin loaded: skip it, print one line, remember the disable.
- Plugins load **after** TUI init and are strictly opt-in; project-dir
  plugins start disabled exactly as in revision 1.
- Every sync call is wrapped for `CatchableError`; a plugin that throws
  or times out repeatedly is demoted (events stop, notice logged).

This is the trade the review chose: direct memory access and zero IPC
in exchange for shared fate, contained by opt-in + guard. It should be
stated in `:plugin help`: an in-process plugin is a native extension of
the 3code binary itself; installing one is installing software with
full user privileges.

### Manifest (harness plugins only)

```
# ~/.config/3code/plugins/lintgate/plugin.toml
name = "lintgate"
lib = "lintgate.so"            ; .dll on Windows
description = "format-on-write gate"
events = ["tool.pre", "tool.post"]   ; lets 3code skip pointless loads
```

## Layer 3: auth plugins: vendor adapters

To answer the open question directly: **yes, an auth plugin ships a
vendor.** Today every vendor's login is a compiled-in module
(`auth_openai`, `auth_google`, `auth_xai`) implementing the internal
closure hooks (`BearerHook`, `ExtraHeadersHook`, `FetchModelsHook`).
Auth plugins externalize exactly that pattern, nothing more:

- given a `[provider]` profile, mint and refresh bearer tokens
  (device-code flow, browser dance, enterprise SSO, whatever the vendor
  invented this quarter),
- contribute per-request headers,
- answer the model-list call when the vendor's API shape demands it.

New subscription vendors, weird proxies, and platform integration
(macOS Keychain token storage instead of plaintext config, corporate
cert profiles) then ship as a `.so` + config without a 3code release.
The contract is two vtable events (`auth.bearer`, `auth.headers`) plus
a declare-refresh-TTL field, all on the netthread, so implementations
must not block; token refresh blocking the request path is the one
place a slow plugin is felt, and the existing patient-retry machinery
already tolerates it.

## Layer 4: skills bundling

Unchanged from revision 1 and now the *primary* path: a plugin (or an
`mcpwrap` registration) may name a `skills/` directory whose markdown
joins `skillsDirs()` precedence (project > user > built-in). For
harness plugins this ships usage prose; for capability plugins it is
the whole interface, and `mcpwrap skill` generates it.

## What we deliberately do not expose

- **MCP in the model path.** No schema mounting, no MCP client in
  3code, no `tools/call` dispatch. `mcpwrap` is the only door, and it
  exits to a shell.
- **New model-facing tools from plugins.** Capabilities are commands;
  the fixed per-family tool surface stays fixed (it is what the models
  were trained on). A plugin that needs model interaction uses hooks,
  the bar, or ships a CLI.
- **Message-list mutation.** Plugins never see the conversation array.
- **UI internals.** `setBarText` and `emitTranscript` are the entire
  UI surface in v1, through vetted entry points, because the layout
  engine is fragile by admission. No drawing, no panes, no widget
  anything; everything a plugin shows is text in the transcript (the
  vim bet: one medium beats N APIs). More setters only after
  visual-test coverage per `.agents/testing.md`.
- **Plugin installation or enablement by the agent.** The model can
  never write config/plugin dirs; default sandbox policy gains that
  deny rule regardless of the plugin system.

## Trust model

- Harness plugins: native code in-process, full privileges, opt-in,
  crash-guarded, project-dir copies disabled until the user enables
  (answer remembered in *user* config, never in the repo).
- Capability CLIs: ordinary programs run via the sandboxed bash tool,
  so they are fenced by the existing `.sandbox` policy like any other
  command. This is a genuine advantage over MCP mounting: a mounted
  MCP tool escapes the sandbox policy by construction, a wrapped CLI
  cannot.
- Veto and rewrite messages carry plugin provenance so the model can
  distinguish harness policy from its own errors.

## Conceived plugins (revised)

**`github` via mcpwrap (capability).** `mcpwrap add github -- npx -y
@modelcontextprotocol/server-github`; `mcpwrap skill github` writes the
catalog line's target. Session cost: 15 tok/call + one ~400 tok skill
read, and the sandbox policy governs its network and file access.

**`lintgate` (harness, `tool.pre`).** Runs the project formatter on
every write/patch, vetoes with the reformat diff. Zero model-facing
surface; now also fast enough (no IPC) to run on `file.write` without
a thought.

**`approve` (harness, `tool.pre` + `askUser`).** Veto-any on
destructive bash (`git push --force`, `rm -rf`, `drop table`) resolved
by a synchronous y/n in the editor line mid-tool-call. The demo of why
in-process matters: the hook asks the human *through* the TUI and the
model receives the answer as a tool result. Out-of-process designs
cannot do this cleanly.

**`secretkeeper` (harness, `tool.post`).** Strips key-shaped strings
from every tool result before it enters context. Saves tokens, stops
secrets riding to the provider. Sees bash, read, and mcpwrap output
alike.

**`dbguard` (harness, `tool.pre`).** Watches bash commands hitting the
project DB CLI (or an `mcpwrap sqlite` subcommand), parses the SQL,
vetoes destructive statements outside an explicit session flag. Policy
plugin guarding a capability plugin; they need not know about each
other.

**`tokenmeter` (harness, `turn.end` + `setBarText`).** Appends usage to
a local ledger and renders a live month-total in the status bar.
`model.retry` events can flip the bar to "quota hold, retry in 14m".

**`testwise` (harness + bundled skill).** Logs test-run signatures
across sessions; its bundled skill teaches the model to `cat` the log
before refactoring a "broken" test that is merely flaky. Harness memory
that survives `:clear`.

**`vendor-xyz` (auth).** A new subscription provider's device-code
login + Keychain token storage, shipped as a `.so` the day the vendor
launches, no 3code release needed.

## Implementation sketch

Two deliverables, loosely coupled:

1. **`mcpwrap`** (new tool, ~700 loc): stdio JSON-RPC client,
   `add`/`skill` subcommands, tools.json cache, flag mapping from JSON
   Schema, text output with caps. Standalone; testable without 3code;
   immediately useful to other agents.
2. **Harness plugins** (~800 loc in 3code): `plugin/api.nim` SDK,
   `dynlib` loader + ABI check + crash marker, event pump wired into
   `turns.nim`/`actions.nim` at exactly six call sites, `:plugin` TUI
   command, `[plugins]` config, sandbox deny rule for config dirs, the
   seven host services (`setBarText`, `askUser`, `emitTranscript`,
   `post`+`setTimer`, `registerCommand`, `lastResult`, `bindKey`), the
   `:` command dispatch table, and one example plugin (`lintgate`) as
   the reference implementation and test fixture.

Also in scope per the vim lesson: the `formatter = "..."` setting
(`'formatprg'` analog, the 90% of lintgate that belongs in config) and
the `path:line:col:` issue-line convention for plugin-issued messages
(the quickfix analog, textual, free today, navigable later).

Auth plugins slot into 2 (~120 loc) once the two host services prove
the boundary. Visual tests per `.agents/testing.md` cover the
`askUser` editor-line prompt and the bar segment; the rest is protocol
and can be testament-tested headlessly.

Deferred: `mcpwrapd` daemon, more UI setters, a static compile-in tier
(`plugins/*.nim` compiled into source builds, zero ABI risk, for users
who live in the toolchain anyway).
