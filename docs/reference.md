.. title:: 3code - reference

## Introduction

This is the reference half of the documentation: every config file option,
every command-line switch, every interactive command, in one place. The
[manual](manual.html) explains how to get things done; this page tells you
exactly what a key does and where it lives.

## Command line switches

```
usage: 3code [options] [prompt...]
       3code good                   # list known-good provider/variant combos
       3code sandbox restrict DIR -- CMD   # run CMD sandboxed (alias: sb)
       3code setup                  # one-time elevated sandbox setup (Windows)
```

| switch | effect |
| --- | --- |
| `-m`, `--model PROVIDER[.MODEL]` | pick a model from the config, overriding `[settings] current` |
| `-c`, `--config FILE` | add FILE to the config layer stack for this run, replacing the user config; repeatable, later files win per key (see [Config file](#config-file)) |
| `-C`, `--config-clear [FILE]` | clear the config stack — user config and project `.3code/config` are not read — then read FILE if given; later `-c` layers stack on top of it |
| `-r`, `--resume[=ID]` | resume the latest session from this directory, or a specific one by ID (`-r ID`, `-rID`, `-r=ID`, `-r:ID`, `--resume=ID`; every value option takes these forms) |
| `-i`, `--interactive` | drop into the REPL after running an initial prompt; without it, a prompt argument runs once and exits |
| `-l`, `--list` | list recent sessions for this directory (max 20) and exit |
| `-a`, `--all` | with `-l` / `-f`: every directory, not just this one |
| `-f`, `--find TERMS...` | search session transcripts for TERMS and exit (case-insensitive; a quoted arg is a phrase) |
| `--page N` | later screenful of `--list` / `--find` results |
| `-g`, `--good` | list known-good provider/variant combos and exit |
| `-x`, `--experimental` | allow combinations outside the known-good list |
| `-p`, `--private` | private mode: only allow-private providers/models run (see [Private mode](manual.html#private-mode)) |
| `--no-sandbox` | disable sandbox enforcement for this run (bash runs unconfined) |
| `-D`, `--debug` | colored debug trace to stderr |
| `--acp` | speak [ACP v1](manual.html#agent-client-protocol) on stdio as the agent, for editors and custom clients (takes no prompt) |
| `--rpc[=PORT]` | serve the plain-text RPC surface for 3code-app on loopback (headless, one session per process) |
| `-v`, `--version` | print version (release builds carry branch/commit provenance) |
| `-h`, `--help` | the usage message, including the config path |

Subcommands: `good` (same as `--good`), `sandbox` / `sb` (run a command
under the [filesystem policy](manual.html#what-is-sandboxed)), `setup` and
`unsetup` (Windows sandbox/network-wall install and removal, see
[network rules](manual.html#network-rules)).

A prompt given as an argument runs one turn and exits (oneshot); `-r`
continues the directory's latest session the same way. Exit codes: 0 for
a completed turn, 2 usage, 3 config, 1 crash. See
[Scripting](manual.html#scripting) in the manual for the pattern and its
parsing limitation.

## Interactive commands

Everything typeable at the `❯` prompt. Tab completes commands, provider
names, model names, and paths where supported.

| command | effect |
| --- | --- |
| `:help` / `:?` | command and key list with current bindings |
| `:tokens` | token usage for this session (input, cached, output, total) |
| `:clear` | reset the conversation, keep provider and model |
| `:model` | list models for the current provider, `*` marks the current |
| `:model X` | switch to model X within the current provider |
| `:model P.X` | switch to model X on provider P in one word (the `-m` spelling) |
| `:provider` | list configured providers; the current one shows its model |
| `:provider X` | switch to provider X |
| `:provider add` | add a provider (interactive wizard, verified) |
| `:provider add X` | same, with X as name, URL, or API key |
| `:provider edit X` | edit provider X (url, key, models) |
| `:provider update X` | replace provider X's model list (key and url unchanged) |
| `:provider new [X]` | list models the provider serves that the config doesn't list yet (all providers when X is omitted) |
| `:provider pull [X [M...]]` | append those models to X's list, or every provider's; specific models optional |
| `:provider rm X` | remove provider X |
| `:reasoning` | list reasoning levels for the current model, `*` marks active |
| `:reasoning X` | switch reasoning level |
| `:streaming` | show streaming mode |
| `:streaming on/off` | toggle SSE streaming; off is the reliable fallback for flaky SSE |
| `:verifier` | show the goal-mode verifier (off = the session model checks) |
| `:verifier list` | list the verification-class models available to you |
| `:verifier X` | run goal checks on X (a listed verifier, or any model of the current provider) |
| `:verifier on/off` | toggle the verifier without losing the selection |
| `:notify` | show notify mode |
| `:notify on/off` | toggle the desktop notification that fires when a turn ends |
| `:retry` | retry now: cut a backoff wait (the curve resets) or resend a data-less in-flight request |
| `:retry list` | show patient-retry mode |
| `:retry on/off` | toggle patient retry of 429/5xx/network errors |
| `:private` | show private mode and trusted providers |
| `:private on/off` | toggle private mode for this session (bar recolors) |
| `:private allow X [M]` | trust provider X, optionally one model, with private data |
| `:prompt` | show the active system prompt (compiled-in, or the [file override](manual.html#system-prompt-override) if one matched) |
| `:show [N]` | show the full output of tool call N (default: last) |
| `:cmd [N]` | show the full command of bash tool call N (default: last), the multiline text the banner previews |
| `:cmd N edit` | open that command in $VISUAL/$EDITOR (`vi`/`notepad` fallback) |
| `:log` | list all tool calls this session |
| `:sessions` | list recent sessions saved in this directory (max 20) |
| `:session` | show this session's ID (for `--resume=ID`) |
| `:resume` | list this directory's sessions; `:resume ID` swaps the running 3code onto that session |
| `:summarize` | collapse old turns into a synthetic recap |
| `:btw Q` | ask the model a side question about the conversation; answered async under a dim `💬` block, never enters the context, its tokens added to the bar |
| `:version` | show the running 3code version |
| `:sandbox` / `:sb` | the sandbox state line, then the active rules when it enforces (`:sandbox show` is the same dump) |
| `:sandbox on/off` | toggle sandbox enforcement |
| `:sandbox allow T` | add a writable/connectable rule |
| `:sandbox readonly P` | add a read-only rule |
| `:sandbox deny T` | add a deny rule |
| `:sandbox ask P` | deny P, but offer a one-key approval (`f` file / `d` dir / `n` no) when a sandboxed command or a `read`/`write`/`patch`/`apply_patch` call is blocked on P |
| `:sandbox edit` | open the policy file in `$VISUAL`/`$EDITOR`, reload on quit |
| `:plugins` | list loaded plugin libraries, hooks, call counts, registered tools |
| `:plugin debug on/off` | trace every plugin call to `THREECODE_DEBUG_LOG` (or stderr) |
| `:! CMD` | run a shell command yourself, output streamed live to scrollback only |
| `:quit` / `:q` / `:exit` | leave |

### Key bindings

Default keys at the prompt. `:help` prints the ones in effect;
[rebinding keys](manual.html#rebinding-keys) covers how to change them.

| key | action |
| --- | --- |
| Enter | submit; on an empty prompt, continue the ongoing session (a turn runs with nothing appended) |
| Shift+Enter or Alt+Enter | insert a newline |
| Up / Down | move through visual rows, then history |
| Ctrl+Arrow | move by word |
| Cmd+A | select all (kitty keyboard protocol terminals) |
| Ctrl+U | delete to start of line |
| Ctrl+W | delete the previous word |
| Ctrl+K | delete to end of line |
| Alt+D / Ctrl+Delete | delete the next word |
| Ctrl+T | transpose characters around the cursor |
| Ctrl+K / Ctrl+U | delete to end / start of line (into the kill ring) |
| Ctrl+W / Alt+D | delete previous / next word (into the kill ring) |
| Ctrl+Y | yank the last kill |
| Alt+Y | cycle older kills right after Ctrl+Y |
| Alt+. | insert the last word of the previous history entry |
| Ctrl+_ or Ctrl+/ | undo; a typed run retracts in one step |
| Alt+R | revert to the recalled entry as recorded (empty draft at the prompt) |
| Alt+T | transpose the words around the cursor |
| Alt+U / Alt+L / Alt+C | upcase / downcase / capitalize the next word |
| Ctrl+Q | insert the next key literally (a real tab, an escape byte) |
| Ctrl+] | jump to the next occurrence of the next typed character |
| Ctrl+@ or Alt+Space | set the mark (binds `exchange-point-and-mark` to swap back) |
| Ctrl+R / Ctrl+S | incremental history search: type to narrow, Ctrl+R/Ctrl+S step older/newer, Enter submits, Esc accepts, Ctrl+G aborts |
| Ctrl+Shift+R | retry now: cut a backoff wait (the curve resets) or resend a data-less in-flight request; the `retry` shortcut, distinct from Ctrl+R only on kitty-protocol terminals |
| Alt+P / Alt+N | history search completed at Enter |
| Alt+< / Alt+> | jump to the oldest entry / back to the draft |
| Ctrl+L | clear the screen |
| Alt+E | edit the input buffer in $VISUAL/$EDITOR |
| Ctrl+X Ctrl+E | same (emacs edit-and-execute-command) |
| Ctrl+C | clear current input; cancel the turn when it is empty |
| Esc | same as Ctrl+C |
| Ctrl+D | exit |

## Config file

### The layer stack

3code reads config as a stack of layers, lowest first; a key set by a
later layer wins. Three kinds of layer:

- the **user config** — `~/.config/3code/config` on Linux,
  `~/Library/Application Support/3code/config` on macOS,
  `%APPDATA%\3code\config` on Windows; `XDG_CONFIG_HOME` overrides the
  base directory on every platform.
- **explicit layers** — every `-c FILE` / `--config FILE`, in command-line
  order. Any `-c` replaces the user config for that run (the original
  single-`-c` meaning: point a run at a different config, isolated from
  yours).
- the **project config** — the nearest `.3code/config` found walking up
  from the working directory to the filesystem root. It always applies
  last, so a repository pin outranks everything; `-C` is the explicit
  opt-out. `.3code/` is already the project slot for skills, prompt
templates, and per-directory settings, so the config joins its own file
there.

| invocation | read stack (later wins) |
| --- | --- |
| `3code` | user config, then project |
| `3code -c a` | a, then project |
| `3code -c a -c b` | a, b, then project |
| `3code -C a -c b` | a, b (no user config, no project) |
| `3code -c a -C b` | b (the `-C` resets everything) |
| `3code -C` | empty stack (first-run state) |

`-C` / `--config-clear [FILE]` clears the stack — the implicit layers
included — and then adds its operand when given. `3code -h` prints the
exact stack a run would read and the file it would write.

Merge rules, per key, later layer winning:

- `[settings]` scalars: per key.
- `current`: the highest layer that sets it. A project-layer `current` also
  owns model selection for the directory — the per-directory sticky
  selection cannot defeat the repo pin.
- `[provider]` blocks: by name. A later same-name block replaces the
  earlier one except that a missing `key` or `url` is inherited from the
  namesake below — an API key stays in your user config while a
  committed project config pins providers and models.
- `[params]`: per (provider, model) scope, per key.
- `[search]`, `[colors]`, `[shortcuts]`: per key.

The security switches are the one exception: `sandbox` and
`sandbox_wall_warn` (and `dirconfig`) in a project `.3code/config` are
governed by the per-directory store rules — a repository file may tighten
an off sandbox but never weaken an on one (see
[project settings](manual.html#project-settings-cannot-weaken-the-sandbox)).

Every layer is validated on its own, so an error names the offending file
and line (`path:line: ...`).

### Writes

The write target is the last explicit `-c`/`-C` layer, else the user
config; 3code rewrites it whenever providers or models change. The project
config is never written — it is a hand-maintained baseline. Only the write
target's own provider definitions (plus providers added during the
session) persist: a definition that came from another layer stays in that
layer's file, and a `current` naming such a provider never lands in the
target. A long-lived session layered over a project config does not notice
project-file edits made mid-session; restart to pick them up.

Values are Nim string literals, always wrapped in double quotes. parsecfg
treats `:`, `=`, and `#` as syntax in unquoted values, so an unquoted URL or
API key can silently truncate. `;` and `#` start comments. An unknown
section is a startup error with a `file:line:` pointer, so a typo cannot
quietly disable a setting. An unknown key prints a `file:line:` warning at
startup and is ignored, so a config written by a newer 3code still boots.
Annotated example: `docs/config.example` in the repository.

A minimal config:

```
[settings]
current = "baseten.glm5"

[provider]
name = "baseten"
url = "https://inference.baseten.co/v1"
key = "..."
models = "zai-org/GLM-5"
```

### settings

Keys under `[settings]`:

| key | values | meaning |
| --- | --- | --- |
| `current` | `PROVIDER[.MODEL]` | the default for directories without their own pick; `-m` overrides it. `:provider`/`:model` stick in the directory's `.3code` store instead: they cascade from the nearest store up the parent chain, and this value is the floor |
| `notify` | `on`/`off` (default on) | desktop notification when a turn ends; off on Termux |
| `streaming` | `on`/`off` (default on) | SSE streaming; `off` uses plain request/response, the reliable fallback for providers with flaky SSE |
| `sandbox` | `on`/`off` (default on) | filesystem sandbox enforcement; `off` also silences the Windows host-rules warning. This file is the only place that may disable the sandbox: a project's `.3code/config` can turn it on but never off (and never silence `sandbox_wall_warn`) |
| `sandbox_enabled` | `on`/`off` | alias for `sandbox` in the user config; in a store, `sandbox` wins when both are set |
| `dirconfig` | `project`/`user` (default project) | where directory-specific settings stores live: a `.3code/` directory in each project, or a per-directory directory under `~/.config/3code/dirs/`. Only in `user` mode may a store's `[settings]` carry a per-directory `sandbox = off`; project stores may tighten (on) but never weaken (off) the sandbox and its warning. Settings cascade nearest-wins for everything else (`current`, ...) |
| `patient_retry` | `on`/`off` (default on) | long backoff for 429/5xx/network errors (see [patient retry](manual.html#patient-retry)); `patient-retry` spelling accepted |
| `sandbox_wall_warn` | `on`/`off` (default on) | the Windows warning shown when host rules exist but `3code setup` has not run. Project stores cannot turn it off |
| `tone` | `auto`/`dark`/`light` (default auto) | color palette selection; `auto` detects the terminal background via OSC 11. The legacy key `mode` and value `bright` still work |
| `bash_path` | full path | Windows only: force a specific bash; auto-detection order is `bash_path`, PortableGit, Git for Windows, MSYS2, legacy msys64 tree |
| `bash` | `auto` or full path (default auto) | any OS: a full path overrides all detection; `auto` keeps the normal order |
| `system-command-prefixes` | characters (default `:`) | characters that introduce commands; whitespace between them is optional, each non-whitespace character is one prefix, duplicates are ignored, and a later line replaces the set. Default `:` leaves slash-prefixed input (`/usr/bin`, URLs) as ordinary prompts; `": /"` opts in — `/start` then recognizes, dispatches and completes exactly like `:start` (tab completion keeps the typed prefix), at the cost of slash-prefixed input being subject to command interpretation; `system_command_prefixes` spelling accepted |
| `max_timeout` | seconds (default 600) | the one setting for long builds: raises both the bash ceiling (what a model-requested `timeout` is clamped to) and the default cap (what a run gets when the model passes no `timeout`, 120 out of the box). `max_timeout = 1800` and a 30-minute compile survives whether or not the model asks for more time; `max-timeout` spelling accepted |
| `force_timeout` | seconds | every bash run gets exactly this cap, regardless of what the model requested (or omitted); `force-timeout` spelling accepted. When set it wins over both the model's `timeout` and `max_timeout`. Rarely needed now that `max_timeout` also raises the default; it remains the blunt instrument for boxes where nothing may run long, in either direction |
| `banner_lines` | lines (default 1) | how many lines of a multiline bash command the `$` banner shows; the rest collapses into a linked `… +N lines · T<idx>.cmd ↗` tail row. `:cmd N` prints the whole command, `:cmd N edit` opens it in $VISUAL/$EDITOR; `banner-lines` spelling accepted |
| `auto-update` | `true`/`false` | self-update on launch; default on for prebuilt binaries, off for source builds. Nightly builds report branch and commit |
| `verifier_model` | `PROVIDER.MODEL` | the model goal mode's satisfaction check runs on (see [verifier models](manual.html#verifier-models)); a decision model answers typed questions in one request. Not set = the session model checks (the default) |
| `verifier` | `on`/`off` | enable/disable the selected verifier without clearing it; absent means on while a model is selected |
| `allow-empty-prompt` | `on`/`off` (default on) | submitting an empty prompt continues the ongoing session: a turn runs on the messages as they stand, appending no user message; `allow_empty_prompt` spelling accepted |
| `user_agent` | template (default `3code $version`) | User-Agent header sent on every model request. Variables: `$version` (the full build version, e.g. `0.9.2-main-a1b2c3d4a`), `$branch` (`-main`), `$commit` / `$hash` (`-a1b2c3d4`), `$stage` (`-unstaged` when the build's sources differed from HEAD; each empty when not applicable), `$os`, `$arch`, and `$$` for a literal `$`. Unknown `$names` pass through verbatim; `user-agent` spelling accepted |
| `dirconfig` | `project` (default) / `user` | where per-directory settings stores live: `<dir>/.3code` in the directory itself, or `~/.config/3code/dirs/<dir>` under your config root (stores there are user-owned, so their sandbox switches are authoritative; see [project settings](manual.html#project-settings-cannot-weaken-the-sandbox)) |

### provider

One `[provider]` section per provider; repeat the section header for each.
Sections may share a `url` and `key`; two sections with the same `name` are
a config error.

| key | meaning |
| --- | --- |
| `name` | provider name, used in `current` and `:provider` |
| `url` | OpenAI-compatible base URL |
| `key` | API key (empty for `auth = "oauth"` subscription logins) |
| `models` | space-separated model IDs offered by `:model` |
| `current_model` | the model `:model` last picked here; switching back to the provider returns to it. Written automatically |
| `auth` | `oauth` for browser-OAuth subscription logins (`supergrok`, `chatgpt`) |
| `family` | experimental-only override that picks the system-prompt branch by family name, for combos off the known-good list. The same name drives the [prompt-file override](manual.html#system-prompt-override) |
| `model_prefix` | legacy: prepended to bare `models` names; expanded on load, never written back |

### params

`[params]` sections override the known-good request parameters
per (provider, model).
`provider` scopes to one provider; `model` is optional: omit it (or leave it
empty) and the entry covers every model of that provider. A model-scoped
entry beats a provider-wide one; among equals the last section in the file
wins. Unset keys keep the known-good value.

| key | values | meaning |
| --- | --- | --- |
| `temperature` | float | sampling temperature |
| `max-tokens` | int | per-turn output budget |
| `think-back` | `none`/`turn`/`all` | how much of the assistant's own `reasoning_content` is replayed in request history. `none` strips it everywhere (strict validators), `turn` keeps only the active tool loop, `all` keeps every turn (deepseek demands it; glm/kimi reward it) |
| `context-window` | int, tokens | drives compaction thresholds and the context gauge |
| `allow-private` | bool | trust this provider (or just this model) with [private mode](manual.html#private-mode) data; model-scoped beats provider-wide, `false` revokes |

### search

The `[search]` section configures the `web_search` tool.

| key | values | meaning |
| --- | --- | --- |
| `engine` | `exa`/`parallel`/`brave` (default exa) | search backend. No automatic failover: the chosen engine is used as-is |
| `exa-key` | string | Exa paid tier (Exa runs keyless otherwise); also read from `EXA_API_KEY` |
| `brave-key` | string | required for the brave engine; also read from `BRAVE_API_KEY` |
| `key` | string | legacy bare key, filed under the active engine |

### colors

Under `[colors]`, the white-family colors respond to the light/dark tone;
the colorful colors (cyan, green, red, magenta) are fixed in both tones.

| key | default (dark) | default (light) | meaning |
| --- | --- | --- | --- |
| `bright-white` | `\x1b[97m` | `\x1b[30m` | primary text: command help, `:command` tokens |
| `off-white` | `\x1b[38;5;252m` | `\x1b[38;5;238m` | tool banners, prompt chrome |
| `dim-white` | `\x1b[38;5;244m` | `\x1b[38;5;250m` | subtle FYI text |
| `token-bar` | `\x1b[36m` | same | the live token bar |
| `private-bar` | `\x1b[35m` | same | the bar while [private mode](manual.html#private-mode) is on |

Values are quoted ANSI escape sequences; parsecfg interprets backslash
escapes, so `"\x1b[36m"` becomes a real ESC byte. A plain key sets both
tones; a `-light` suffixed key (`bright-white-light`) sets the light tone
only and wins there.

### shortcuts

`[shortcuts]` handles key rebinding for every editor command; see [rebinding
keys](manual.html#rebinding-keys) in the manual for the key-name grammar
and the full command list. Values merge onto the defaults; an empty value
unbinds a command.

### plugins

The `[plugins]` section controls the native plugin tier (hooks and
tools in dynamically loaded libraries); the keys are covered in detail
in [plugins](plugins.html).

| key | effect |
| --- | --- |
| `disable` | comma-separated plugin names (lib file stems) to skip at load |
| `tools` | `"on"` advertises plugin-registered tools to the model (opt-in) |
| `debug` | `"on"` traces every plugin call with mutation diffs |
| `lib` | extra plugin discovery directory, scanned before the defaults |

## Environment variables

| variable | effect |
| --- | --- |
| `XDG_CONFIG_HOME` | relocates the config root: config file, user skills, global prompts |
| `XDG_DATA_HOME` | relocates the data root: sessions, history, auth tokens, builtin skills |
| `THREECODE_ALLOW_ROOT` | set to 1 to allow running as root (POSIX; refused otherwise) |
| `THREECODE_PLUGIN_SYNC_MS` | sync-hook deadline override in ms (default 2000) |
| `THREECODE_PLUGIN_TOOL_MS` | plugin tool-exec default timeout in ms (default 120000) |

Both XDG variables work on every platform, including Windows, and expect
absolute paths. They exist so tests and isolated setups can redirect all of
3code's state; the platform defaults apply when they are unset.

Diagnostics, useful when reporting a bug:

| variable | effect |
| --- | --- |
| `THREECODE_DEBUG_LOG` | append the `-D` debug trace to this path (POSIX) |
| `THREECODE_TRACE_FILE` | write startup timing milestones here (startup-trace builds) |
| `THREECODE_TERMDBG` | arm terminal-model probes, logged to this path, for rendering bug reports |
| `THREECODE_FORCE_SYNC_OUTPUT` | set to 1 to re-enable DEC 2026 synchronized repaints (off by default) |

Variables starting with `THREECODE_TEST_` belong to the test harness and
change without notice.
