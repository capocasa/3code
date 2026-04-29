# 3code

**An experiment in getting frontier-plan value from a pay-as-you-go API key.**

3code is a coding agent for any OpenAI-compatible chat endpoint. You give it
a task, it reads and writes files and runs shell commands until the task is
done or you stop it. One binary, no web UI, no telemetry, no project config.

The premise: a hosted open-weights model behind a third-party endpoint can
compete with a frontier subscription if the agent stops splurging tokens
*and* stops splurging the user's attention. Frugality runs both directions
— small system prompt, terse tool output, supersede-aware history
compaction (earlier full-file writes and reads are elided once a later
action on the same path lands), and a soft ceiling before the context window
fills; plus advanced ergonomics (streaming reasoning ticker, type-ahead,
tab-completion on commands, supersede + summarize compaction, loop guard,
session resume, `:show`/`:log`/`:tokens` introspection) so the human
doesn't have to babysit. Bring your own endpoint, pay for the work, not
for the chatter.

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

Providers without tool-call support aren't supported in the default mode.
Nearly every major OpenAI-compatible endpoint has them in 2025.

### Text mode (experimental)

`:mode text` swaps the protocol for parsed fenced code blocks. The
harness sends no tool schema; the model emits `` ```bash …``` `` for
shell, `path/to/file\n``` …``` ` for whole-file writes, and
`<<<<<<< SEARCH / ======= / >>>>>>> REPLACE` inside a fenced block for
patches. The harness parses, runs, and feeds back results as a `user`
message. `:mode tools` (or `:mode toggle`) flips it back. Pin the
default per-provider with `mode = "text"` in the config file.

The point: skip the tool schema bytes per request, skip the tool_call
JSON wrapping per response, work on providers without (or with weak)
tool-call support. The cost: no `tool` role separation, so the model
sees results inside a `user` message — older / cheaper models follow
the convention, frontier ones occasionally narrate around it.

## Use

    3code "add a --dry-run flag to the main command"

or drop into interactive:

    3code

Type `:q`, `exit`, `quit`, or hit Ctrl-D to leave.

## Auto-update

Prebuilt binaries from the [install script](https://3code.capocasa.dev/install)
or GitHub releases quietly self-update on launch (throttled to one
check per 4h). The next launch after a swap prints one dim line:
`· updated to vX.Y.Z`.

Source builds (`nimble install`) default to **off** — if you built it,
you own it. Toggle either way in `~/.config/3code/config`:

    [settings]
    auto_update = "true"   ; or "false"

## Caveats

- No permissions, sandbox, or approval prompts. It runs what the model says
  to run, in the current working directory.
- Supersede-aware compaction is lossless for the model's next turn but can
  trip replay if you `:show` an elided tool result. The body is gone by
  design. Banner stays, exit code stays.

Use in a scratch directory or a clean git working tree. `git diff` is your
safety net.

## Changelog

    0.2.6   anchored status bar (token + prompt rows), shared live/replay markdown render, all https via curl (fixes macos ssl across verify/summarize/auto-update)
    0.2.5   prompt: explicit web-research skill trigger, unknown tool returns akError, tighter token slots
    0.2.4   token line: tighter slots, ≡ for cache, live status during stream
    0.2.3   ui polish: strip preamble from replay, restyle resumed banner, plain inline code
    0.2.2   share live/replay render helpers, persist per-turn usage, ctrl+c aborts provider wizard
    0.2.1   refuse to run as root (override: THREECODE_ALLOW_ROOT=1)

## License

MIT.
