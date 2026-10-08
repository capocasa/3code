# Plugins

3code loads out-of-tree plugin libraries at startup: `.so` on Linux,
`.dylib` on macOS, `.dll` on Windows, discovered in:

1. `$XDG_DATA_HOME/3code/lib` (`~/.local/share/3code/lib` on Linux)
2. `/usr/local/lib/3code`, `/usr/lib/3code` (Linux; `%ProgramFiles%\3code\lib` on Windows)

First match wins on name collision. A plugin is any native library
speaking the 3code C ABI. A hook fires only for libraries that export
it — there is no manifest, no registration call.

Plugins are native code running in-process with your full user rights.
Install only libraries you trust. The default sandbox already fences
the model out of the lib directory, so an agent cannot install one for
you.

## Writing a plugin in Nim

One module. Types first, your hooks in the middle, the SDK included
last:

```nim
include threecode/pluginabi   # types + helpers (from the 3code repo's src/)
import std/json

proc onPrompt*(ev: var TcPromptEvent) =
  if "deploy" in tcView(ev.prompt):
    tcAssignStr(ev.prompt, tcView(ev.prompt) & "\n[checked by myplugin]")

proc onToolPre*(ev: var TcToolPreEvent): cint =
  if tcView(ev.name) == "write" and "migrations" in tcView(ev.args):
    tcAssignStr(ev.message, "myplugin: migrations are frozen today")
    return tcVeto
  tcAllow

proc registerTools*(s: ptr TcState) =
  discard s.registerTool("weather", "current conditions",
    """{"type":"function","function":{"name":"weather",
       "parameters":{"type":"object","properties":{
         "city":{"type":"string"}},"required":["city"]}}}""")

proc onToolExec*(ev: var TcToolExecEvent): int32 =
  tcAssignStr(ev.output, "sunny")
  0

include threecode/plugin_sdk   # exports the tc_* hooks (LAST)
```

Build and install:

    nim c --app:lib --mm:orc --threads:on -o:myplugin.so myplugin.nim
    cp myplugin.so ~/.local/share/3code/lib/

If the plugin wants to teach the model something, drop a skill in
`~/.config/3code/skills/myplugin.md` — that is the whole install
convention.

`tests/testdata/plugin_fixture.nim` in the 3code repo is the canonical
worked example (every hook, heavily commented). Build plugins with
`--threads:on`: the host calls you from its own thread, and the SDK
must register that thread with your runtime's GC before your first
allocation.

## Hooks

All hooks run on one dedicated host thread, one call at a time, in
plugin load order. `TcStr` fields are read-only; `TcMutStr` fields you
may edit in place (`tcAssignStr`). Every pointer is valid only during
the call.

| export | when | can change |
|---|---|---|
| `tc_on_prompt` | user submits a prompt | the prompt |
| `tc_on_system_prompt` | once per provider/model/family | the system prompt |
| `tc_on_tool_pre` | before each tool call runs | args; verdict: allow / veto / rewrite / takeover / wrap |
| `tc_on_tool_result` | after a tool call | the output, the exit code |
| `tc_on_turn_start` / `tc_on_turn_end` | turn lifecycle (usage, elapsed) | — |
| `tc_on_model_retry` | provider error with backoff | — |
| `tc_on_session_start` | session load | — |
| `tc_on_compact` | history summarization | — |
| `tc_on_file_write` | write/patch/apply_patch landed | — |
| `tc_register_tools` + `tc_tool_exec` | register model-facing tools | — |

Multiple plugins chain: mutations waterfall in load order, a veto
short-circuits and names the plugin in the tool result.

`tc_on_tool_pre` verdicts:

- `tcAllow` (0) — proceed.
- `tcVeto` (1) — skip the call; `message` becomes the tool result.
- `tcRewrite` (2) — you edited `args`; proceed with the new ones.
- `tcTakeover` (3) — skip execution; `message`/`code` are the whole
  result. The plugin did the work itself — that runs outside the
  sandbox, full trust.
- `tcWrap` (4) — run the original (sandboxed) between `message` (pre)
  and `post`.

## Registered tools and the token cost

`[plugins] tools = "on"` (default off) advertises plugin-registered
tools to the model. Be aware of what you are opting into: the tool
array is sent with every model request, so every registered schema is
billed on every call whether used or not — roughly 300-900 tokens per
call for a small curated schema. The gate exists so mounting is a
deliberate choice. The cheaper alternative is usually a skill plus a
CLI the model drives through bash.

## Debug output

`:plugin debug on` (or `[plugins] debug = "on"`) traces every plugin
call to `THREECODE_DEBUG_LOG` (or stderr): the hook, the plugin,
elapsed time, verdicts, and a line diff of anything a plugin mutated.
`:plugins` lists loaded libraries, their subscribed hooks, call
counts, registered tools, and any load-time skips (wrong ABI version,
failed load, disabled by name).

## Config reference

    [plugins]
    disable = "slowplugin, other"  # skip by lib file stem
    tools = "on"                   # advertise registered tools (opt-in)
    debug = "on"                   # per-call trace with mutation diffs
    lib = "/extra/search/dir"      # additional discovery dir

## Timeouts and failure handling

Sync hooks (prompt, system prompt, tool pre/result/exec) have a 2 s
budget (120 s for tool exec, plugin-declared via `registerTool`'s
`timeoutMs`). A timeout applies the default outcome, logs a strike,
and flags `cancelled` so well-behaved plugins wind down (poll
`tcCancelled(tcCurrentState)` in long loops). Three strikes demotes a
plugin's sync hooks for the session. A plugin exception is caught and
traced; a plugin crash takes the process down — no process isolation
exists in the in-process tier.
