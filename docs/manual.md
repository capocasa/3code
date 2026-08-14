.. title:: 3code - the economical coding agent

## Introduction

3code is the coding agent I wanted for my own work: capable, quiet, and not
forever looking for new ways to spend tokens. It works with OpenAI-compatible
providers, including free tiers, flat-rate coding plans, and local servers.

The design rule is simple: get a correct result with the least model work,
token use, and computer time. Open models, especially GLM, are good enough for
most of my programming work. 3code gives them a focused prompt, a small tool
set, persistent sessions, and a terminal interface that stays out of the way.

## Quickstart

First, give 3code somewhere to run inference: an API provider or a local
OpenAI-compatible server. Local models can work, though small ones still have a
rough time with difficult coding tasks.

### Get a provider

There are plenty of compatible providers. A free tier is a good place to
start. Pay for one after you know which model actually works for your projects.

#### Free providers

[NVIDIA Build](https://build.nvidia.com) and
[Novita](https://novita.ai) often have useful free models. The lists and rate
limits move around, as free things tend to do, so check before signing up.

#### Flat-rate coding plans

The [z.ai coding plan](https://z.ai/subscribe) is my main setup. GLM is capable,
inexpensive, and happy to keep working through a long task.

3code can also log in with ChatGPT Plus/Pro and SuperGrok or X Premium+
subscriptions. These are separate from OpenAI and xAI API billing, despite the
similar names.

#### EU providers

When data must stay under EU jurisdiction, I use
[TensorX](https://tensorx.ai). Nebius and Eurouter are also in the provider
catalog.

#### Low-cost providers

DeepInfra, OpenCode, nano-gpt, Novita, and similar aggregators serve quantized
open models cheaply. Quality and availability vary, so a little comparison
shopping pays off.

#### Other models

DeepSeek, MiniMax, Kimi, Tencent Hy, Qwen, Grok, and LongCat are all supported
somewhere. The registry changes too often for a copied list to age gracefully,
so ask 3code for the current one:

```
3code --good
```

OpenRouter and Eurouter are handy when you want to try many models through one
account. Once you settle on one, a direct provider account removes a service
from the request path and is often cheaper.

### Install

```
# macOS / Linux
curl -fsSL https://3code.capocasa.dev/install | sh

# Windows (PowerShell)
irm https://3code.capocasa.dev/install.ps1 | iex
```

### Termux on Android arm64

Releases include `3code-termux-arm64.tar.gz`. If you prefer to build it where
it will run, Termux only needs:

```
pkg install nim git openssl
nimble install https://github.com/capocasa/3code
```

The binary uses Termux OpenSSL for TLS. Android has no OS sandbox or desktop
notifications, but the in-process path checks still apply. Notifications do
nothing and automatic updates are disabled. To update, install again or unpack
a new archive.

### Add a provider

Run `3code` in your project directory. With no provider configured, it goes
straight to the setup wizard. You can return to the wizard later with:

```
:provider add
```

The first field accepts:

- a catalog name, such as `nvidia`, `zai`, `xai`, or `openai`
- a provider URL when `--experimental` is enabled
- an API key with a recognized prefix
- `supergrok` for SuperGrok or X Premium+ login
- `chatgpt` for ChatGPT Plus/Pro login

The wizard lists the provider's known-good models (a curated registry of
combinations 3code has tested) and saves your selection as-is. With
`--experimental` the wizard queries the provider's models endpoint and
verifies each selection with a 1-token call; press Esc to stop verification.

### Run your first prompt

```
❯ Build a Hello World program in Nim
```

That is enough to get started.

## Providers and authentication

`:provider` lists configured providers and marks the current one. `:model`
does the same for its models. Both commands have tab completion, so there is no
need to memorize catalog names.

```
:provider nvidia
:model gpt-oss-120b
```

### API keys

Most providers use an API key, and the wizard recognizes the common prefixes.
For an unknown provider or a custom URL, start 3code with `--experimental`.
The flag is deliberate: compatibility is likely, not promised.

### xAI and SuperGrok

An `xai-` key creates a normal `xai` provider. Enter `supergrok` instead to
sign in with a SuperGrok or X Premium+ subscription. They can live side by
side, which is useful if you have both kinds of account.

The browser OAuth flow stores tokens in:

```
$XDG_DATA_HOME/3code/auth/xai.json
```

On POSIX systems the file is created with mode 0600, and tokens refresh
automatically. Switch accounts with `:provider xai` and
`:provider supergrok`.

### OpenAI and ChatGPT

An OpenAI API key creates an `openai` provider. Enter `chatgpt` instead to use
a ChatGPT Plus/Pro subscription. As with xAI and SuperGrok, both providers can
exist together.

ChatGPT login opens the OpenAI browser OAuth flow and stores tokens in:

```
$XDG_DATA_HOME/3code/auth/openai.json
```

On POSIX systems the file is created with mode 0600, and tokens refresh
automatically. ChatGPT model listings and requests go through the Codex backend
at `chatgpt.com/backend-api/codex`.

OpenAI and ChatGPT use the Responses API. Other OpenAI-compatible providers use
Chat Completions. The Codex backend is internal, unversioned, and intended for
first-party clients. It works, but using it through 3code is your
responsibility.

Switch accounts with:

```
:provider openai
:provider chatgpt
```

## Interactive use

At the interactive prompt, describe the result you want or enter a command
beginning with `:`. Tab completes commands, provider names, model names, and
paths where supported.

3code loads `3CODE.md` and `AGENTS.md` from the project directory and its
parents. These are good homes for project rules, build commands, and style
requirements. To include a file directly in a prompt, prefix its path with
`@`:

```
Review @src/parser.nim and add tests for malformed input.
```

Useful input keys:

| key | action |
| --- | --- |
| Enter | submit |
| Shift+Enter or Alt+Enter | insert a newline |
| Up / Down | move through visual rows, then history |
| Ctrl+Arrow | move by word |
| Ctrl+U | clear the input buffer |
| Ctrl+W | delete the previous word |
| Ctrl+L | clear the screen |
| Ctrl+C | clear current input |
| Esc | cancel the current operation |
| Ctrl+D | exit |

If you forget one, `:help` prints the current command and key list.

## Usage monitoring

Each response ends with a compact token receipt:

```
  ○12%  ↑4.2k  ↻18k  ↓1.1k  8s
```

| field | meaning |
| --- | --- |
| `○N%` | context window used |
| `↑` | fresh input tokens |
| `↻` | cached input tokens |
| `↓` | output tokens |
| `Xs` | elapsed time |

The receipt updates while the response streams. If a field is missing, the
provider did not report it. 3code declines to invent accounting.

## Patient retry

Patient retry is enabled by default. On `429` limits, `5xx` responses, and
network failures, 3code backs off exponentially rather than failing
immediately. Delays are capped at 2048 seconds and retries can continue for
about 36 hours, long enough to outwait a rolling limit or a bad connection.

After the short initial retry period, attempts become part of the transcript:

```
Usage limit reached for the past 5 hours. (code 429). retry 42/64 in 2048s
```

Use these commands to inspect or change the setting:

```
:retry
:retry off
:retry on
```

Even with patient retry off, 3code gives transient failures about a minute
before returning to the interactive prompt. The setting is stored as
`patient_retry` in `[settings]`. Press Esc to cancel the wait.

## Reasoning

`:reasoning` lists the levels the current model actually supports and marks the
active one:

```
:reasoning
:reasoning high
:reasoning off
```

The valid values depend on the model:

- binary reasoning models use `off` and `on`
- many models use `low`, `medium`, and `high`
- GLM 5.2 uses `off`, `high`, and `max`
- OpenAI o-series models use `low`, `medium`, and `high`
- GPT-5.0 uses `minimal`, `low`, `medium`, and `high`
- GPT-5.1 and later add `none`
- GPT-5.4 and GPT-5.5 add `xhigh`
- GPT-5.6 adds `max` and does not use `minimal`
- GPT-5.5 Pro uses `medium`, `high`, and `xhigh`; GPT-5 Pro uses `high`
- GPT-4.x has no reasoning setting

3code sends the right provider-specific field for the selected model.
Providers have not settled on one common reasoning scale.

When a provider streams reasoning text, 3code keeps it moving through a
one-line ticker above the interactive prompt. It is not added to the
transcript.

## Known-good models

Provider APIs differ in small, consequential ways. 3code therefore keeps a
registry of combinations tested with the right prompt, reasoning settings,
token fields, and context size.

Print the current registry with:

```
3code --good
```

For combinations outside the registry, `--experimental` opens the gate.

## Sessions

List the 20 most recent sessions for the current directory:

```
3code --list
# or
3code -l
```

Resume the latest session:

```
3code --resume
```

Resume a session by ID:

```
3code --resume=abc123
# or
3code -r:abc123
```

Sessions are listed per working directory, so unrelated projects stay out of
each other's history. Provider prompt caches may expire before a saved session
does. The session will still resume, but its old context may no longer get the
cache discount.

## Context management

`:clear` starts a new conversation with the same provider and model:

```
:clear
```

`:summarize` replaces older turns with a generated recap. It is useful when the
task must continue but the context has become expensive:

```
:summarize
```

If the old work is no longer relevant, clear it. A fresh context is safer than
a summary of things the model no longer needs.

## Chunked mode

For a large mechanical task, ask the model to split the work into files. Each
chunk ends by calling `context_clear` with instructions for the next one. The
model carries the plan forward and leaves the spent context behind.

Example:

```
Divide this task into 4-6 chunks in impl-N.md files.
End each file by calling context_clear with instructions to read the next file.
Then execute chunk 1.

Task: add test coverage to the parser module.
```

Chunked mode works best when little human input is needed, such as adding basic
tests across many modules. If the model forgets to load the next chunk, the
task was probably too difficult or the plan too vague.

## Cybernetic mode

Cybernetic mode is the sturdier option for a long coding task. Give the model a
worktree and ask it to use the built-in cybernetic planning skill.

The skill:

1. writes a plan file with concrete tasks
2. implements one task
3. updates the plan with results and new information
4. clears context and tells the next session to load the plan
5. repeats until all tasks are complete
6. reviews the completed work

The current task keeps its detailed context while the plan file keeps the
durable state. This loses less information than repeatedly summarizing all the
old work.

## No sub-agents

3code does not provide sub-agents. They use plenty of tokens, and I have not
seen enough benefit to justify the little management consultancy they form.
For parallel or long-running work, use worktrees with cybernetic mode.

## Sandbox

The model is useful, but it does not need the run of your entire computer.
3code applies a filesystem policy to every tool call. Bash commands also enter
an OS sandbox, and host rules can fence their network access.

Exactly one policy source is active:

1. `.sandbox` in the project directory, if it exists
2. `~/.config/3code/sandbox`, if you created it
3. the built-in default, held in memory

Policies do not cascade or merge. One file wins, so what is allowed remains
inspectable. A project file replaces the user file. 3code never creates the
user file; create it yourself to set defaults for projects without `.sandbox`.

The first `:sandbox allow`, `:sandbox readonly`, `:sandbox deny`, or
`:sandbox edit` command in a project copies the effective policy to `.sandbox`
before changing it. You get a complete project policy, not a mysterious patch
on top of another file.

### Policy format

A policy has one rule per line:

==============  ==============================================
Word            Meaning
==============  ==============================================
``deny``        no read, write, or network connection
``readonly``    read and execute, for paths only
``allow``       read and write a path, or connect to a host
==============  ==============================================

The target type is determined by its first character:

==============  ==============================================
Start           Target
==============  ==============================================
``/``           absolute path
``X:``          Windows drive path
``~``           path under the home directory
``.``           path relative to the project directory
letter/digit    hostname or IP address, with an optional port
==============  ==============================================

Paths are intentionally explicit. Use `./foo` for a project-relative path. An
access word on its own means the project directory itself:

```
deny /
allow
readonly /var
deny ./secrets
```

Rules are read from top to bottom and the last matching path rule wins. In this
example the project is writable, `/var` is read-only, and `./secrets` is denied.
Everything else is denied because unmatched paths are denied by default.

Blank lines and lines beginning with `#` are ignored. An access word only has
special meaning when followed by whitespace or the end of the line, so a host
such as `deny.example.com` remains a hostname.

### Built-in default

On macOS, Linux, and other POSIX systems, the built-in policy is:

```
deny /
allow /tmp
allow /var/tmp
allow
allow *
```

This lets the model write in the project and temporary directories, not wander
through other user files. System programs, libraries, configuration, and device
files get a read-only baseline so commands can still run. `allow *` leaves the
network open.

On Windows, the built-in policy is:

```
deny /
allow ~/AppData/Local/Temp
allow
```

Windows grants network capability when no host rules are present.

### Network rules

With no host rules, every host is allowed. `allow *` says the same thing
explicitly. To close the network completely, use:

```
deny *
```

Host targets may be domains or IP addresses. A single `allow` rule turns the
policy into an allowlist: that host works and all others do not.

```
allow api.example.com
```

A single `deny` rule does the inverse: that host is blocked and the rest of the
network stays open.

```
deny telemetry.example.com
```

IP addresses work the same way, for example `allow 192.0.2.10` or
`deny 192.0.2.10`. The spelling matters: bare `foo` is a hostname, while
`./foo` is a file or directory named `foo` in the working directory.

A host without a port matches every port. Add one when it matters, as in
`allow github.com:443`. Wildcards work too: `allow *.example.org` allows that
domain pattern.

As with paths, the last matching rule wins. Any `allow` host rule makes
unmatched hosts denied. With only `deny` host rules, unmatched hosts remain
allowed. This is the small detail that decides whether you have made an
allowlist or a blocklist.

On Linux and macOS, fenced commands reach the network through a local CONNECT
and SOCKS5 allowlist proxy. Linux puts the command in a network namespace;
macOS confines it to loopback with Seatbelt. 3code sets the standard proxy
variables and a Git SSH proxy command for the child process. Denied HTTP
connections return 403.

On Windows, host rules require one elevated setup command:

```
3code wall setup-windows
```

Without that setup, 3code warns and runs the command without a network fence.
That is safer than pretending the fence exists. Set `sandbox_wall_warn = off`
in `[settings]` if you no longer need the warning.

### Editing the policy

Use an editor or the sandbox commands:

```
:sandbox
:sandbox show
:sandbox edit
:sandbox allow /opt
:sandbox readonly /var
:sandbox deny ./secrets
:sandbox on
:sandbox off
```

`:sandbox edit` tries `$VISUAL`, then `$EDITOR`, then the platform default.
Changes take effect when the editor exits. Rule commands store project paths in
portable `./foo` form and reload immediately.

`:sandbox off` disables filesystem and network enforcement for the session.
The setting is stored as `sandbox = off` in `[settings]`. Use `:sandbox on` to
restore enforcement.

To allow the full filesystem, replace the policy with `allow /`. Without host
rules, the network is unrestricted too. This is yolo mode. 3code makes you ask
for it explicitly and will not have the bright idea on its own.

### Policy file protection

A policy is not much use if the model can edit it. The file tools therefore
cannot change `.sandbox` or `~/.config/3code/sandbox`. After loading the policy,
3code adds hidden read-only guards for both files. They do not appear in
`:sandbox show`, and later rules cannot override them.

macOS and Windows enforce these guards for Bash and in-process tools. Landlock
cannot subtract a read-only file from an already writable root. On Linux, the
in-process tools still enforce the guard, but a Bash command under `allow /`
can write the policy file. Avoid `allow /` if policy-file protection matters.

A denied Bash command usually reports `Permission denied`. 3code includes the
active policy path in denial messages, saving you from debugging the wrong
layer.

### What is sandboxed

The read, write, and patch tools check paths inside 3code itself. Bash needs a
stronger boundary, so commands are re-executed through:

```
3code sandbox --policy FILE restrict -- COMMAND
```

`3code sb` is the short alias. The command and all its children inherit the OS
restriction. The sandbox process reads the policy afresh, so an edit applies to
the next Bash launch.

### Platform behavior and fallback

The Bash backend uses Landlock on Linux, Seatbelt on macOS, and restricted
tokens plus ACLs on Windows. 3code probes it at startup rather than assuming it
works. Old Linux kernels and containers whose seccomp policy blocks Landlock
can fail the probe.

If the OS backend is unavailable, Bash runs without filesystem confinement.
The in-process read, write, and patch checks remain active. This keeps 3code
usable, but the distinction matters: an arbitrary Bash command is then outside
the filesystem fence.

## Library API

A Nim program can embed the same agent loop without bringing along the terminal
interface:

```nim
import threecode

let session = initAgentSession(
  AgentOptions(model: "deepinfra.deepseek-v3.2"))

session.onEvent = proc(event: AgentEvent) =
  case event.kind
  of aevDelta: stdout.write event.text
  of aevRetry, aevTool: stderr.writeLine event.text
  else: discard

let reply = session.prompt("Run the tests and fix the failure.")
echo session.command(":tokens")
session.close()
```

`prompt` blocks until the model finishes calling tools and returns its reply.
Meanwhile, `onEvent` receives text, reasoning, tool output, retry notices, and
usage. `promptAsync` puts the turn on a library-managed thread and reports
failures with `aevError`; `interrupt` cancels it. Sessions use the same provider
config, filesystem policy, locks, and saved format as the CLI.

Only one `AgentSession` may be active in a process, and calls on it are not
thread-safe. In an asynchronous server, keep the session on one worker thread
and pass prompts and events through queues. This avoids sharing session state
across threads.

`example/webserve.nim` is the complete example: the session stays on a worker
thread and events reach the browser through server-sent events.

## Contributing

Developer API documentation is generated at `docs/dev/threecode.html`:

```
nimble devdocs
```

Useful contributions include tested provider/model combinations and bug fixes
with a clear reproduction. Terminal rendering bugs need a visual PTY test that
shows the bad frame before the fix. A test that cannot show the bug has not
reproduced it yet.

## Prior art

3code is influenced by Claude Code, Goose, Pi, and Codex. It chooses different
tradeoffs, but the family resemblance is intentional. As a European, using
Claude Code can feel like driving a turbocharged Ford F-150 to buy a pack of
gum. It is still a fine truck.

3code omits features that do not help it write software reliably with fewer
resources. Economy is the feature, not a billing surprise.
