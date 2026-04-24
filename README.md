# 3code

**The economical coding agent.**

A coding agent for any OpenAI-compatible chat endpoint. You give it a task,
it reads and writes files and runs shell commands until the task is done or
you stop it. One binary, no web UI, no telemetry, no project config.

3code exists because other agents splurge tokens. Every design choice is
weighted against that: a lean system prompt, compact tool output formatting,
supersede-aware history compaction (earlier full-file writes and reads are
elided once a later action on the same path lands), and a soft ceiling
before the context window fills. Bring your own endpoint, pay for the work,
not for the chatter.

The name is a nod to third-party-hosted models: bring your own endpoint.

## Install

    nimble install https://github.com/capocasa/3code

Or clone and `nimble install`. Requires `curl` on `PATH` for streaming
model calls (already installed on basically every POSIX system).

## Configure

Run `3code` with no config and it walks you through adding a provider
(name, base URL, API key, models), verifies it with a one-token test
call, and saves the result. Inside the REPL:

    :provider              list configured providers (current marked with *)
    :provider add          add another one (same wizard)
    :provider use groq     switch current
    :provider use groq.llama-3.1-8b-instant
    :provider rm groq      remove one

Tab completes `:` commands, `:provider` subcommands, and provider names.
The config file lives at `~/.config/3code/config`. You can edit it by
hand too:

    [settings]
    current = "openai.gpt-4o-mini"

    [provider]
    name = "openai"
    url = "https://api.openai.com/v1"
    key = "sk-..."
    models = "gpt-4o-mini, gpt-4o"

    [provider]
    name = "groq"
    url = "https://api.groq.com/openai/v1"
    key = "gsk_..."
    models = "llama-3.3-70b-versatile, llama-3.1-8b-instant"

Values are Nim string literals, always wrap them in double quotes.
parsecfg treats `:`, `=`, and `#` as syntax in unquoted values.

Each `[provider]` block defines one endpoint; `models` is a comma-separated
list. `[settings] current` picks the default as `provider.model` (or just
`provider` to use the first model in its list). Override per-invocation
with `-m`:

    3code -m groq "refactor the http client"
    3code -m groq.llama-3.1-8b-instant "quick one-liner"

## How it works

Reply → execute → loop. Four tools, sent as OpenAI tool calls:

- `bash(command)`, run a shell command.
- `read(path, offset?, limit?)`, read a file or a line range.
- `write(path, body)`, create or overwrite a file.
- `patch(path, edits)`, apply exact-match search/replace edits.

Providers without tool-call support aren't supported. Nearly every
major OpenAI-compatible endpoint has them in 2025.

## Use

    3code "add a --dry-run flag to the main command"

or drop into interactive:

    3code

Type `:q`, `exit`, `quit`, or hit Ctrl-D to leave.

## Caveats

- No permissions, sandbox, or approval prompts. It runs what the model says
  to run, in the current working directory.
- Supersede-aware compaction is lossless for the model's next turn but can
  trip replay if you `:show` an elided tool result. The body is gone by
  design. Banner stays, exit code stays.

Use in a scratch directory or a clean git working tree. `git diff` is your
safety net.

## License

MIT.
