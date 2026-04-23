# 3code

A minimal coding agent. You point it at any OpenAI-compatible chat endpoint,
give it a task, it reads and writes files and runs shell commands until the
task is done or you stop it. About 250 lines of Nim, one binary, no web UI,
no telemetry, no project config.

The name is a nod to third-party-hosted models: bring your own endpoint.

## Install

    nimble install https://github.com/capocasa/3code

Or clone and `nimble install`.

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
The config file lives at `~/.config/3code/config` — you can edit it by
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

Values are Nim string literals — always wrap them in double quotes.
parsecfg treats `:`, `=`, and `#` as syntax in unquoted values.

Each `[provider]` block defines one endpoint; `models` is a comma-separated
list. `[settings] current` picks the default as `provider.model` (or just
`provider` to use the first model in its list). Override per-invocation
with `-m`:

    3code -m groq "refactor the http client"
    3code -m groq.llama-3.1-8b-instant "quick one-liner"

## How it works

Reply → parse → execute → loop. The model is told to emit three kinds of
fenced blocks:

Shell:

    ```bash
    nimble test
    ```

Full-file write (path on the line above the fence):

    src/foo.nim
    ```
    echo "hi"
    ```

Patch with one or more exact-match edits:

    src/foo.nim
    ```
    <<<<<<< SEARCH
    old code that matches byte-for-byte
    =======
    new code
    >>>>>>> REPLACE
    ```

Results go back as the next user message and the loop continues until the
model stops emitting blocks.

## Use

    3code "add a --dry-run flag to the main command"

or drop into interactive:

    3code

Type `:q`, `exit`, `quit`, or hit Ctrl-D to leave.

## Limitations

By design:

- No tool-use protocol (JSON schemas, structured calls). Text parsing only.
- No permissions, sandbox, or approval prompts. It runs what the model says
  to run, in the current working directory.
- No streaming. You wait for the full reply, then it executes.
- No context management. The conversation grows until you exit.
- If the model emits a file containing triple backticks, parsing breaks.

Use in a scratch directory or a clean git working tree. `git diff` is your
safety net.

## License

MIT.
