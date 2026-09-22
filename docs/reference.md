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
| `-r`, `--resume[=ID]` | resume the latest session from this directory, or a specific one by ID |
| `-i`, `--interactive` | drop into the REPL after running an initial prompt; without it, a prompt argument runs once and exits |
| `-l`, `--list` | list recent sessions for this directory (max 20) and exit |
| `-a`, `--all` | with `-l`, accepted but a no-op for now (reserved) |
| `-g`, `--good` | list known-good provider/variant combos and exit |
| `-x`, `--experimental` | allow combinations outside the known-good list |
| `-p`, `--private` | private mode: only allow-private providers/models run (see [Private mode](manual.html#private-mode)) |
| `--no-sandbox` | disable sandbox enforcement for this run (bash runs unconfined) |
| `-D`, `--debug` | colored debug trace to stderr |
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
| `:provider` | list configured providers; the current one shows its model |
| `:provider X` | switch to provider X |
| `:provider add` | add a provider (interactive wizard, verified) |
| `:provider add X` | same, with X as name, URL, or API key |
| `:provider edit X` | edit provider X (url, key, models) |
| `:provider rm X` | remove provider X |
| `:reasoning` | list reasoning levels for the current model, `*` marks active |
| `:reasoning X` | switch reasoning level |
| `:streaming` | show streaming mode |
| `:streaming on/off` | toggle SSE streaming; off is the reliable fallback for flaky SSE |
| `:notify` | show notify mode |
| `:notify on/off` | toggle the desktop notification that fires when a turn ends |
| `:retry` | show patient-retry mode |
| `:retry on/off` | toggle patient retry of 429/5xx/network errors |
| `:private` | show private mode and trusted providers |
| `:private on/off` | toggle private mode for this session (bar recolors) |
| `:private allow X [M]` | trust provider X, optionally one model, with private data |
| `:prompt` | show the active system prompt |
| `:show [N]` | show the full output of tool call N (default: last) |
| `:log` | list all tool calls this session |
| `:sessions` | list recent sessions saved in this directory (max 20) |
| `:session` | show this session's ID (for `--resume=ID`) |
| `:summarize` | collapse old turns into a synthetic recap |
| `:version` | show the running 3code version |
| `:sandbox` / `:sb` | show the active filesystem sandbox rules |
| `:sandbox on/off` | toggle sandbox enforcement |
| `:sandbox allow T` | add a writable/connectable rule |
| `:sandbox readonly P` | add a read-only rule |
| `:sandbox deny T` | add a deny rule |
| `:sandbox edit` | open the policy file in `$VISUAL`/`$EDITOR`, reload on quit |
| `:! CMD` | run a shell command yourself, output to scrollback only |
| `:quit` / `:q` / `:exit` | leave |

## Config file

Location: `~/.config/3code/config` on Linux,
`~/Library/Application Support/3code/config` on macOS,
`%APPDATA%\3code\config` on Windows; `XDG_CONFIG_HOME` overrides the
base directory on every platform. Annotated example: `docs/config.example`
in the repository.

Values are Nim string literals, always wrapped in double quotes. parsecfg
treats `:`, `=`, and `#` as syntax in unquoted values, so an unquoted URL or
API key can silently truncate. `;` and `#` start comments. An unknown
section or key is a startup error with a `file:line:` pointer, so a typo
cannot quietly disable a setting.

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
| `current` | `PROVIDER[.MODEL]` | the provider (and optional model) used at startup; `-m` overrides it, `:provider`/`:model` write it back |
| `notify` | `on`/`off` (default on) | desktop notification when a turn ends; off on Termux |
| `streaming` | `on`/`off` (default on) | SSE streaming; `off` uses plain request/response, the reliable fallback for providers with flaky SSE |
| `sandbox` | `on`/`off` (default on) | filesystem sandbox enforcement; `off` also silences the Windows host-rules warning |
| `patient_retry` | `on`/`off` (default on) | long backoff for 429/5xx/network errors (see [patient retry](manual.html#patient-retry)); `patient-retry` spelling accepted |
| `sandbox_wall_warn` | `on`/`off` (default on) | the Windows warning shown when host rules exist but `3code setup` has not run |
| `tone` | `auto`/`dark`/`light` (default auto) | color palette selection; `auto` detects the terminal background via OSC 11. The legacy key `mode` and value `bright` still work |
| `bash_path` | full path | Windows only: force a specific bash; auto-detection order is `bash_path`, PortableGit, Git for Windows, MSYS2, legacy msys64 tree |
| `bash` | `auto` or full path (default auto) | any OS: a full path overrides all detection; `auto` keeps the normal order |
| `auto_update` | `true`/`false` | self-update on launch; default on for prebuilt binaries, off for source builds. Nightly builds report branch and commit |

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
| `family` | experimental-only override that picks the system-prompt branch by family name, for combos off the known-good list |
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
