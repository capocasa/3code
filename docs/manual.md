.. title:: 3code - the economical coding agent

## Introduction

3code is a coding agent built to use fewer tokens and less local compute.
It works with OpenAI-compatible providers, including free tiers, flat-rate
coding plans, and local servers.

The main design rule is simple: get a correct result with the least model work,
token use, and computer time. Open models, especially GLM, are good enough for
most of my programming work. 3code gives them a focused prompt, a small tool
set, persistent sessions, and a quiet terminal interface.

## Quickstart

You need an API provider or a local OpenAI-compatible server. Local models can
work, but small local models are still limited on difficult coding tasks.

### Get a provider

There are many compatible providers. Start with a free tier, then choose a
paid provider after you know which model works for your projects.

#### Free providers

[NVIDIA Build](https://build.nvidia.com) and
[Novita](https://novita.ai) often provide useful free models. Free model lists
and rate limits change, so check the provider before signing up.

#### Flat-rate coding plans

The [z.ai coding plan](https://z.ai/subscribe) is my main setup. GLM is capable,
inexpensive, and well suited to long agentic tasks.

3code also supports subscription login for ChatGPT Plus/Pro and SuperGrok or X
Premium+. These subscriptions are separate from OpenAI and xAI API billing.

#### EU providers

I use [TensorX](https://tensorx.ai) when data must stay under EU jurisdiction.
Nebius and Eurouter are also available in the provider catalog.

#### Low-cost providers

DeepInfra, OpenCode, nano-gpt, Novita, and similar aggregators serve quantized
open models at low prices. Quality and model availability vary by provider.

#### Other models

DeepSeek, MiniMax, Kimi, Tencent Hy, Qwen, Grok, and LongCat are all supported
on one or more providers. The model registry changes often. Use the live list
instead of relying on a list copied into this manual:

```
3code --good
```

OpenRouter and Eurouter are useful for testing many models through one account.
A direct provider account removes one service from the request path and is
often cheaper.

### Install

```
# macOS / Linux
curl -fsSL https://3code.capocasa.dev/install | sh

# Windows (PowerShell)
irm https://3code.capocasa.dev/install.ps1 | iex
```

### Termux on Android arm64

Releases include `3code-termux-arm64.tar.gz`. You can also build inside
Termux:

```
pkg install nim git openssl
nimble install https://github.com/capocasa/3code
```

The binary uses Termux OpenSSL for TLS. The OS sandbox and desktop
notifications are unavailable on Android. In-process path checks still apply,
and notifications do nothing. Automatic updates are disabled. Install again
or download a new archive to update.

### Add a provider

Run `3code` in your project directory. If no provider is configured, the setup
wizard opens automatically. You can also open it later:

```
:provider add
```

The first field accepts:

- a catalog name, such as `nvidia`, `zai`, `xai`, or `openai`
- a provider URL when `--experimental` is enabled
- an API key with a recognized prefix
- `supergrok` for SuperGrok or X Premium+ login
- `chatgpt` for ChatGPT Plus/Pro login

The wizard fetches the provider's model list, verifies selected models in
parallel, and saves only the models that pass. Press Esc to cancel verification.

### Run your first prompt

```
❯ Build a Hello World program in Nim
```

## Providers and authentication

Use `:provider` to list configured providers. The current provider is marked.
Use `:model` to list its models. Tab completion works for both commands.

```
:provider nvidia
:model gpt-oss-120b
```

### API keys

Most providers use an API key. The setup wizard recognizes common key prefixes.
For an unknown provider or a custom URL, start 3code with `--experimental`.

### xAI and SuperGrok

An `xai-` key creates a normal `xai` provider. Enter `supergrok` to sign in with
a SuperGrok or X Premium+ subscription. The two providers can exist together.

The browser OAuth flow stores tokens in:

```
$XDG_DATA_HOME/3code/auth/xai.json
```

On POSIX systems the file is created with mode 0600. Tokens refresh
automatically. Switch accounts with `:provider xai` and
`:provider supergrok`.

### OpenAI and ChatGPT

An OpenAI API key creates an `openai` provider. Enter `chatgpt` to use a ChatGPT
Plus/Pro subscription instead. The two providers can exist together.

ChatGPT login opens the OpenAI browser OAuth flow and stores tokens in:

```
$XDG_DATA_HOME/3code/auth/openai.json
```

On POSIX systems the file is created with mode 0600. Tokens refresh
automatically. ChatGPT requests use the Codex backend at
`chatgpt.com/backend-api/codex`. 3code uses that backend for model listing and
requests.

OpenAI and ChatGPT use the Responses API. Other OpenAI-compatible providers use
Chat Completions. The Codex backend is an internal, unversioned service for
first-party clients. Using it through 3code is your responsibility.

Switch accounts with:

```
:provider openai
:provider chatgpt
```

## Working in the REPL

Select a model, then describe the result you want. Tab completes commands,
provider names, model names, and paths where supported.

3code loads `3CODE.md` and `AGENTS.md` from the project directory and its parent
directories. Put project rules, build commands, and style requirements there.
You can include file contents in a prompt with `@path`:

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

Run `:help` for the current command and key list.

## Usage monitoring

Each response ends with a token receipt:

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

The receipt updates while a response streams. A missing field means the
provider did not report it.

## Patient retry

Patient retry is enabled by default. It handles `429` limits, `5xx` responses,
and network failures with exponential backoff. The delay is capped at 2048
seconds and the retry period can last about 36 hours. This lets a session wait
through a rolling provider limit or temporary network loss.

After the short initial retry period, each attempt is added to the transcript:

```
Usage limit reached for the past 5 hours. (code 429). retry 42/64 in 2048s
```

Use these commands to inspect or change the setting:

```
:retry
:retry off
:retry on
```

With patient retry off, 3code still retries transient failures for about one
minute before returning to the prompt. The setting is stored as
`patient_retry` in `[settings]`. Press Esc to cancel a retry wait.

## Reasoning

Use `:reasoning` to list the levels supported by the current model. The active
level is marked. For example:

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

3code sends the provider-specific field for the selected model. It does not
assume one reasoning scale works everywhere.

When a provider streams reasoning text, 3code shows it in a one-line ticker
above the prompt. The ticker does not add the reasoning text to the transcript.

## Known-good models

Provider APIs differ in small but important ways. 3code keeps a registry of
provider and model combinations that have been tested with the correct prompt,
reasoning settings, token fields, and context size.

Print the current registry with:

```
3code --good
```

Use `--experimental` to run a combination outside the registry.

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

Session listing is scoped to the current directory. Provider prompt caches may
expire before a saved session does. An old session still resumes, but its old
context may no longer receive cache discounts.

## Context management

`:clear` starts a new conversation with the same provider and model:

```
:clear
```

`:summarize` replaces older turns with a generated recap. Use it when you need
to keep the current task but reduce context use:

```
:summarize
```

A clear context is safer than a summary when the old work is no longer relevant.

## Chunked mode

For a large mechanical task, ask the model to split the work into files. Each
chunk ends by calling `context_clear` with instructions for the next chunk.
This keeps only the context needed for the current step.

Example:

```
Divide this task into 4-6 chunks in impl-N.md files.
End each file by calling context_clear with instructions to read the next file.
Then execute chunk 1.

Task: add test coverage to the parser module.
```

Chunked mode works best for tasks that need little human input, such as adding
basic tests across many modules. If the model forgets to load the next chunk,
the task was probably too difficult or the plan was too vague.

## Cybernetic mode

Cybernetic mode is the preferred way to run a long coding task. Give the model
a worktree and ask it to use the built-in cybernetic planning skill.

The skill:

1. writes a plan file with concrete tasks
2. implements one task
3. updates the plan with results and new information
4. clears context and tells the next session to load the plan
5. repeats until all tasks are complete
6. reviews the completed work

This keeps detailed context for the current task and durable context in the
plan file. It avoids compressing every old detail into a summary.

## No sub-agents

3code does not provide sub-agents. They use many tokens and their benefit is
unclear. Use worktrees with cybernetic mode for parallel or long-running work.

## Sandbox

3code applies a filesystem policy to every tool call. Bash commands also use an
OS sandbox. A network policy can restrict hosts reached by Bash commands.

Exactly one policy source is active:

1. `.sandbox` in the project directory, if it exists
2. `~/.config/3code/sandbox`, if you created it
3. the built-in default, held in memory

Policies do not cascade or merge. The project file replaces the user file.
3code never creates the user file. Create it yourself to define the default for
projects without `.sandbox`.

The first `:sandbox allow`, `:sandbox readonly`, `:sandbox deny`, or
`:sandbox edit` command in a project creates `.sandbox` from the current
effective policy. This gives the project a complete policy before changing it.

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

Use `./foo` for a project-relative path. A bare access word means the project
directory itself:

```
deny /
allow
readonly /var
deny ./secrets
```

Rules are read from top to bottom. The last matching path rule wins. In this
example the project is writable, `/var` is read-only, and `./secrets` is denied.
Anything not matched by a path rule is denied.

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

The project and temporary directories are writable. Other user files are
denied. System programs, libraries, configuration, and device files receive a
read-only baseline so commands can run. `allow *` leaves network access open.

On Windows, the built-in policy is:

```
deny /
allow ~/AppData/Local/Temp
allow
```

Windows grants network capability when no host rules are present.

### Network rules

A host rule enables the network wall for Bash commands. Examples:

```
allow api.example.com
allow github.com:443
deny telemetry.example.com
allow *.example.org
```

A host without a port matches every port. `allow *` permits all hosts. Rules
use ordered, last-match behavior. If the policy contains an `allow` host rule,
unmatched hosts are denied. If it contains only `deny` host rules, unmatched
hosts are allowed.

On Linux and macOS, fenced commands use a local CONNECT and SOCKS5 allowlist
proxy. Linux puts the command in a network namespace. macOS limits it to
loopback with Seatbelt. 3code sets the standard proxy variables and a Git SSH
proxy command for the child process. A denied HTTP connection returns 403.

On Windows, host rules require one elevated setup command:

```
3code wall setup-windows
```

Without that setup, 3code warns and runs the command without a network fence.
Set `sandbox_wall_warn = off` in `[settings]` to hide the warning.

### Editing the policy

Use an editor or REPL commands:

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

`:sandbox edit` opens `.sandbox` with `$VISUAL`, then `$EDITOR`, then the
platform default editor. Changes reload when the editor exits. Rule commands
store project paths in portable `./foo` form and reload immediately.

`:sandbox off` disables filesystem and network enforcement for the session.
The setting is stored as `sandbox = off` in `[settings]`. Use `:sandbox on` to
restore enforcement.

To allow the full filesystem, replace the policy with `allow /`. With no host
rules, network access is also unrestricted. This is yolo mode. It is explicit
and 3code never enables it for you.

### Policy file protection

The model cannot change `.sandbox` or `~/.config/3code/sandbox` through file
tools. 3code adds hidden read-only rules for both files after loading the
policy. These rules do not appear in `:sandbox show` and cannot be overridden
by a later line in the file.

macOS and Windows enforce these guards for Bash and in-process tools. Landlock
cannot subtract a read-only file from an already writable root. On Linux, the
in-process tools still enforce the guard, but a Bash command under `allow /`
can write the policy file. Avoid `allow /` if policy-file protection matters.

A denied Bash command usually reports `Permission denied`. 3code adds the
active policy path to denial messages so the cause is clear.

### What is sandboxed

The read, write, and patch tools check paths inside the 3code process. Bash
commands are re-executed through:

```
3code sandbox --policy FILE restrict -- COMMAND
```

`3code sb` is a short alias. The command and all its children inherit the OS
restriction. The sandbox process reads the policy itself, so a policy edit
applies to the next Bash launch.

### Platform behavior and fallback

The Bash backend uses Landlock on Linux, Seatbelt on macOS, and restricted
tokens plus ACLs on Windows. 3code probes the backend at startup. The probe can
fail on an old Linux kernel or in a container whose seccomp policy blocks
Landlock.

If the OS backend is unavailable, Bash runs without filesystem confinement.
The in-process checks for read, write, and patch remain active. This fallback
keeps 3code usable, but it does not confine arbitrary file access from a Bash
command.

## Library API

Nim programs can embed the same agent loop without the terminal interface:

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

`prompt` blocks until the model finishes calling tools and returns its final
reply. `onEvent` receives text, reasoning, tool output, retry notices, and usage
as they occur. `promptAsync` runs a turn on a library-managed thread and reports
failures with `aevError`. `interrupt` cancels the active turn. Sessions use the
same provider config, filesystem policy, locks, and saved session format as the
CLI.

Only one `AgentSession` may be active in a process. Calls on a session are not
thread-safe. Keep the session on one worker thread and send prompts and events
through queues when embedding it in an asynchronous server.

`example/webserve.nim` is a complete web frontend. It keeps the session on a
worker thread and sends events to the browser with server-sent events.

## Contributing

Developer API documentation is generated at `docs/dev/threecode.html`:

```
nimble devdocs
```

Useful contributions include tested provider/model combinations and bug fixes
with a clear reproduction. A terminal rendering bug must include a visual PTY
test that shows the bad frame before the fix.

## Prior art

3code is influenced by Claude Code, Goose, Pi, and Codex. It chooses different
tradeoffs, but the family resemblance is intentional. As a European, using
Claude Code can feel like driving a turbocharged Ford F-150 to buy a pack of
gum. It is still a fine truck.

3code omits features that do not help it write software reliably with fewer
resources. Economy is the feature, not a billing surprise.
