.. title:: 3code - plugins

## Introduction

A plugin is a native dynamic library (`.so` on Linux, `.dylib` on macOS,
`.dll` on Windows) that 3code loads at startup and calls at fixed points
in its lifecycle: the command line, prompts, tool calls, turns, sessions.
There is no manifest, no registration call, no RPC protocol. The
library exports C functions; the host probes for them; whichever hooks
exist get called.
Each `dynlib` carries its own runtime, so a plugin can be written in
anything that speaks the C ABI, and the reference SDK makes Nim
one-file simple.

Reach for a plugin when you want machinery on the *host* side of the
agent: policy (veto writes to frozen paths, redact secrets from tool
output), instrumentation (usage counters, audit logs, custom
notifications), or a model-facing tool backed by your own code. For
teaching the *model* something, a skill file is still the right tool:
it costs nothing until used, while every plugin-registered tool schema
rides along on every model request. Most plugins want both halves: a
host-side hook implementation plus a small skill that tells the model
how to drive it.

Plugins are native code running in-process with your full user rights.
Install only libraries you trust, from sources you trust. The default
sandbox already fences the model out of the lib directories, so an
agent cannot install one for you.

## The model in one page

Discovery and load:

1. `$XDG_DATA_HOME/3code/lib` (`~/.local/share/3code/lib` on Linux)
2. `/usr/local/lib/3code`, `/usr/lib/3code` (Linux; `%ProgramFiles%\3code\lib` on Windows)

An optional `[plugins] lib = path` dir is scanned first. Files are
sorted by name within each directory; on a stem collision the first
match wins. A candidate that does not export `tc_abi_version`, or whose
version differs from the host's, is skipped and noted in `:plugins`.
Load order is the resulting sorted order, and load order is hook call
order.

Everything else follows from one design decision: **all plugin code runs
on a single dedicated host thread, one call at a time, in load order**.
Never on the turn, net, or input threads; a plugin never needs locks of
its own to be safe against the host. Sync hooks (prompt, system
prompt, tool pre/result/exec, init/register/shutdown) round-trip with a
deadline, so a slow plugin cannot stall a turn forever. Async hooks
(turn, session, compact, file-write events) are fire-and-forget copies
into a bounded queue.

Multiple plugins chain: mutations waterfall in load order (plugin two
sees plugin one's edit), a veto or takeover short-circuits the chain
and names the plugin in the tool result.

## Writing a plugin: the short manual

### The shape of a module

One Nim file. The ABI types first, your hook procs in the middle, the
SDK include last. The SDK include is what turns your `onPrompt` into
the exported `tc_on_prompt` the host probes for, and it registers the
host's plugin thread with your library's garbage collector before your
first allocation:

```nim
include threecode/pluginabi   # types + helpers (FIRST)
import std/[json, os]         # your imports

proc onPrompt*(ev: var TcPromptEvent) =
  if "deploy" in tcView(ev.prompt):
    tcAssignStr(ev.prompt, tcView(ev.prompt) & "\n[checked by myplugin]")

include threecode/plugin_sdk   # exports the tc_* hooks (LAST)
```

Define any subset of the optional procs; only defined ones are exported
and thus subscribed by the host. Hook filtering (say, only some tools)
is your job, not the host's: a cheap `if tcView(ev.name) != "write":
return` guard at the top is the intended idiom.

Build and install (the ABI modules come from the 3code source tree;
`-p:` it in, or use an installed package):

    nim c --app:lib --mm:orc --threads:on -p:~/p/3code/src -o:myplugin.so myplugin.nim
    cp myplugin.so ~/.local/share/3code/lib/

`--threads:on` is not optional: the host calls you from its own thread,
and without the SDK's foreign-thread registration your first allocation
there is undefined behavior. Run `:plugins` to confirm the load (it
lists subscribed hooks and call counts), then `:plugin debug on` to
watch it live.

### Editing data in place

Read a field with `tcView`, replace it with `tcAssignStr`. The buffer
you may grow is capped (see [strings and
buffers](#strings-and-buffers)); an edit that does not fit is dropped
and the host logs it. Do not write past `len`, do not free anything,
do not retain a pointer after your proc returns: every pointer the host
hands you is valid only for the duration of the call.

### Steering tool calls

`onToolPre` sees every tool call before execution and returns a
verdict:

```nim
proc onToolPre*(ev: var TcToolPreEvent): cint =
  if tcView(ev.name) == "write" and "migrations" in tcView(ev.args):
    tcAssignStr(ev.message, "myplugin: migrations are frozen today")
    return tcVeto
  tcAllow
```

- `tcAllow` (0): proceed unchanged.
- `tcVeto` (1): skip the call; `message` becomes the tool result the
  model sees.
- `tcRewrite` (2): you edited `args` (JSON text); proceed with the new
  ones.
- `tcTakeover` (3): skip execution; `message` and `code` are the whole
  result. You did the work yourself, which runs *outside* the sandbox,
  with your full rights. That is the point, and the risk.
- `tcWrap` (4): run the original, sandboxed, with `message` prepended
  and `post` appended to its output. Multiple wraps compose in load
  order.

`onToolResult` fires after a call lands and can edit the output before
the model reads it (redaction is the classic use) and even the exit
code.

### Registering a model-facing tool

Two procs cooperate: one registers, one executes.

```nim
proc registerTools*(s: ptr TcState) =
  discard s.registerTool("weather", "current conditions",
    """{"type":"function","function":{"name":"weather",
       "parameters":{"type":"object","properties":{
         "city":{"type":"string"}},"required":["city"]}}}""")

proc onToolExec*(ev: var TcToolExecEvent): int32 =
  tcAssignStr(ev.output, "sunny")
  0
```

`registerTool` is legal only inside `registerTools`. The schema is an
OpenAI function-tool definition; the name must not collide with a
builtin tool (`bash`, `read`, `write`, ... check `:plugins` for
rejections) or an already-registered one. The optional last argument is
a per-call timeout in milliseconds; 0 means the host default (120 s).

Tools are advertised to the model only when `[plugins] tools = "on"`,
which is deliberately off by default: the tool array is stateless and
rides every model request, so every registered schema is billed on
every call whether used or not, roughly 300-900 tokens for a small
curated one. The gate makes mounting a deliberate choice. Executions
run unsandboxed in the plugin, like any plugin code. Drop a skill in
`~/.config/3code/skills/myplugin.md` teaching the model when and how
to call the tool; that is the whole install convention.

### Adding a subcommand or an option

The same registration pattern reaches the command line. A subcommand
makes `3code <name> ...` yours; an option adds a `--flag` the main
parser accepts and hands to your plugin:

```nim
proc registerCli*(s: ptr TcState) =
  discard s.registerCliCommand("deploy", "run the deploy pipeline")
  discard s.registerCliOption("deploy-env", 'E', "target environment",
                              takesValue = true)

proc onCliCommand*(ev: var TcCliCommandEvent): int32 =
  let args = parseJson(tcView(ev.args))   # JSON array, verbatim
  tcAssignStr(ev.output, "deploying to " & $args)
  0

proc onCliOptions*(ev: var TcCliOptionsEvent) =
  let opts = parseJson(tcView(ev.options)) # JSON object
  if opts.hasKey("deploy-env"): target = opts["deploy-env"].getStr
```

`registerCliCommand`/`registerCliOption` are legal only inside
`registerCli` (which runs at load, before argv is parsed — that is the
whole reason plugins now load that early). Names are lowercase
`a-z0-9-`, one word. Anything the built-in CLI already owns is refused:
the builtin subcommands (`good`, `provider`, `sandbox`, ...), the
builtin option names (`--model`, `--resume`, ...) and the builtin short
letters (`-m`, `-r`, ...), plus your own earlier registrations. Check
the bool return or `:plugins` to see a refusal.

A registered subcommand dispatches when it is the FIRST bare word on
the command line; everything after it is yours verbatim (flags,
sub-subcommands, `--`), like `3code provider` owns its rest. Fill
`ev.output` and return the exit code; the host prints the output and
exits with your code. The budget is the tool-exec one (120 s default).

Registered options are accepted wherever builtin options are
(`--opt value`, `--opt=value`, `-Zvalue` for a registered short) and
collect into a JSON object delivered once to every plugin exporting
`tc_on_cli_options`, before any session work: value options as
strings, flags as `true`. `3code -h` lists both surfaces in an "added
by plugins" block, so your additions are discoverable.

### Long work and interruption

A sync hook that runs long gets its default outcome applied without it
(see [failure handling](#failure-handling)). Poll
`tcCancelled(tcCurrentState)` in any loop that might outlive its
budget, including tool execs (Esc during a turn sets the flag):

```nim
while moreWork() and not tcCancelled(tcCurrentState):
  doChunk()
```

### Beyond Nim

The ABI is plain C. A plugin in C, Rust (`extern "C"`), Zig, or
anything else just exports the `tc_*` symbols itself, honors
`abi`/`structSize` (treat a larger host struct as trailing unknown
bytes; refuse nothing except a `structSize` smaller than yours), and
keeps the memory rules above. The fixture in
`tests/testdata/plugin_fixture.nim` in the 3code repo is the canonical
worked example of every hook, heavily commented.

## Hook reference

| export | Nim proc | budget | fires |
| --- | --- | --- | --- |
| `tc_abi_version()` | - | - | probed at load; must equal the host version exactly |
| `tc_init(s)` | `init(s): cint` | 2 s | once after load, before any hook; return 0 |
| `tc_register_tools(s)` | `registerTools(s)` | 2 s | once after init |
| `tc_register_cli(s)` | `registerCli(s)` | 2 s | once after init, before argv is parsed |
| `tc_shutdown(s)` | `shutdown(s)` | - | at process exit, before unload |
| `tc_on_prompt(s, ev)` | `onPrompt(ev: var TcPromptEvent)` | 2 s | user submits a prompt |
| `tc_on_system_prompt(s, ev)` | `onSystemPrompt(ev: var TcSysPromptEvent)` | 2 s | once per provider/model/family (memoized), then cached |
| `tc_on_tool_pre(s, ev)` | `onToolPre(ev: var TcToolPreEvent): cint` | 2 s | before each tool call |
| `tc_on_tool_result(s, ev)` | `onToolResult(ev: var TcToolResultEvent)` | 2 s | after each tool call |
| `tc_tool_exec(s, ev)` | `onToolExec(ev: var TcToolExecEvent): int32` | declared, default 120 s | the model calls a registered tool |
| `tc_on_turn_start(s, ev)` | `onTurnStart(ev: var TcTurnEvent)` | async | a turn begins |
| `tc_on_turn_end(s, ev)` | `onTurnEnd(ev: var TcTurnEndEvent)` | async | a turn ends (usage, elapsed) |
| `tc_on_model_retry(s, ev)` | `onModelRetry(ev: var TcRetryEvent)` | async | provider error enters backoff |
| `tc_on_session_start(s, ev)` | `onSessionStart(ev: var TcSessionEvent)` | async | a session loads |
| `tc_on_compact(s, ev)` | `onCompact(ev: var TcCompactEvent)` | async | history gets summarized |
| `tc_on_file_write(s, ev)` | `onFileWrite(ev: var TcFileWriteEvent)` | async | write/patch/apply_patch landed |
| `tc_cli_command(s, ev)` | `onCliCommand(ev: var TcCliCommandEvent): int32` | 120 s default | the user ran `3code <your-subcommand> ...` |
| `tc_on_cli_options(s, ev)` | `onCliOptions(ev: var TcCliOptionsEvent)` | 2 s | after argv parse, once, when any registered option was given |

Async means fire-and-forget: the host copies a small POD event into a
bounded queue (256 entries, oldest dropped under pressure) and moves
on. Do not mutate async events as if the host were waiting; it is not.

Event structs. `TcStr` fields are read-only views; `TcMutStr` fields
may be edited in place. Every struct also carries `abi` and
`structSize` first.

**TcPromptEvent**: `prompt` (mut, 1 MiB), `cwd`, `sessionPath`,
`provider`, `model`.

**TcSysPromptEvent**: `prompt` (mut, 512 KiB), `provider`, `model`,
`family`. The result is cached per (provider, model, family) for the
process lifetime.

**TcToolPreEvent**: `name`, `callId`, `family`; `args` (mut, 256 KiB,
JSON text of the tool arguments); out fields `verdict`, `message` (4
KiB), `post` (4 KiB), `code`. Set the verdict by returning it.

**TcToolResultEvent**: `name`, `args`, `elapsedMs`, `diff` (the
bash-style diff when a tool produced one); `output` (mut, 1 MiB) and
`code` (pointer, editable) shape what the model sees.

**TcToolExecEvent**: `name`, `args`; out fields `output` (mut, 1 MiB)
and `code`. Your whole job: fill `output`, return the exit code as
`ev.code` (the proc's return value).

**TcTurnEvent**: `turn`, `promptTokens`, `cwd`.

**TcTurnEndEvent**: `turn`, `promptTokens`, `completionTokens`,
`reasoningTokens`, `elapsedMs`, `interrupted`, `sessionPath`.

**TcRetryEvent**: `provider`, `model`, `status` (HTTP status or 0),
`category`, `backoffS`, `attempt`.

**TcSessionEvent**: `sessionPath`, `cwd`, `provider`, `model`,
`resumed`, `messages`.

**TcCompactEvent**: `before`, `after` (message counts), `summary`.

**TcFileWriteEvent**: `path` (project-relative when possible), `bytes`,
`kind` (0 write, 1 patch, 2 apply_patch).

**TcCliCommandEvent**: `name`; `args` is the JSON array text of the
arguments that followed the subcommand, verbatim. Out fields:
`output` (mut, 1 MiB) and `code`. Set `code` by returning it.

**TcCliOptionsEvent**: `options`, the JSON object text of the options
collected from argv (`{"deploy-env": "prod", "verbose": true}`).
Read-only.

## Strings and buffers

`TcStr` is a read-only `data`+`len` view into host memory, not
NUL-terminated. `TcMutStr` is a host-allocated buffer with `len <= cap`
at all times. `tcView` copies a view into a Nim string (the only
allocating conversion; call it when you need the bytes),
`tcAssignStr` copies your bytes back, silently doing nothing when they
do not fit `cap` (the host logs the drop).

The host sizes each editable buffer at twice the payload, floored at
16 KiB, capped per field: prompt 1 MiB, system prompt 512 KiB, tool
args 256 KiB, tool result and tool-exec output 1 MiB, tool-pre
message/post 4 KiB. A payload already over its cap skips the hook
entirely rather than truncating silently; the debug trace shows the
skip. Ordinary edits always fit.

## State, services, cancellation

`TcState` is the per-plugin context the host passes as the first
argument everywhere. It is stable for the process lifetime, so a
pointer stashed in `userData` survives between calls. Fields: `abi`,
`structSize`, `pluginName`, `userData`, `cancelled` (set to 1 by the
host when the user interrupts while your call is in flight), and
`services`.

`TcServices` are host callables:

- `log(msg)`: append to the debug trace, tagged with your plugin name.
  Safe from any hook.
- `registerTool(name, description, schemaJson, timeoutMs)`: legal only
  inside `registerTools`. Returns 0 on success, 1 outside registration,
  2 for an empty name, 3 for a builtin tool name, 4 for a duplicate.
  The Nim-side `s.registerTool(...)` wrapper returns a bool.
- `registerCliCommand(name, help)`: legal only inside `registerCli`.
  Adds a `3code <name>` subcommand. Same return-code scheme; 3 means a
  builtin subcommand owns that name, 4 a plugin already registered it.
- `registerCliOption(longName, shortName, help, takesValue)`: legal only
  inside `registerCli`. Adds a `--longName` option and, when
  `shortName` is a non-empty string, a `-x` short form. 3 covers a
  builtin long name or short letter, 2 a bad name.

The SDK keeps the current call's state pointer in the threadvar
`tcCurrentState`; `tcCancelled(tcCurrentState)` is the polite way to
poll for interruption.

## Failure handling

A sync hook has a deadline (2 s, or the tool-exec budget; the env vars
`THREECODE_PLUGIN_SYNC_MS` and `THREECODE_PLUGIN_TOOL_MS` retune them).
On timeout the default outcome applies without you: allow for verdicts,
the original text for prompts and outputs, an error result for a
plugin tool. The plugin takes a strike, the host flags `cancelled` so
a well-behaved hook winds down, and three strikes demote the plugin:
its sync hooks are skipped for the rest of the session (`:plugins`
shows DEMOTED). A Nim exception in a hook is caught and traced; a
segfault takes the process down. There is no process isolation in this
tier, which is why the lib directories are yours, not the model's.

## Config and debug

| key | effect |
| --- | --- |
| `disable = "slow, other"` | skip plugins by lib file stem |
| `tools = "on"` | advertise registered tools to the model (opt-in) |
| `debug = "on"` | per-call trace with mutation diffs |
| `lib = "/path"` | extra discovery dir, scanned first |

`:plugins` (or `:plugin list`) reports loaded libraries, subscribed
hooks, call counts, strikes, registered tools, and every load-time
skip with its reason. `:plugin debug on` traces every call to
`THREECODE_DEBUG_LOG` (or stderr): the hook, the plugin, elapsed
milliseconds, verdicts, and a line diff of anything a plugin mutated,
which is the fastest way to see your plugin actually doing something.

## ABI stability

The ABI version is 1 and must match exactly; a mismatched library is
skipped, never shimmed. Additive changes (trailing struct fields) bump
nothing: `structSize` negotiation absorbs them, and both sides treat a
larger counterpart struct as unknown trailing bytes. Any incompatible
layout or signature change bumps `TcAbiVersion`, and old plugins are
refused loudly at load rather than corrupting memory quietly.

`TcServices` has no size field, so a slot added to it later (the CLI
registration calls above) is safe only for old-plugin-on-new-host; a
plugin calling a service slot the running host never had reads past
its allocation. Keep the pluginabi you compile against no newer than
the 3code that will load you.
