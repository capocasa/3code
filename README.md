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

Write a config file at `~/.config/3code/config`:

    [3code]
    profile = openai

    [openai]
    url = r"https://api.openai.com/v1"
    key = r"sk-..."
    model = "gpt-4o-mini"

    [groq]
    url = r"https://api.groq.com/openai/v1"
    key = r"gsk_..."
    model = "llama-3.3-70b-versatile"

Values are Nim string literals — use `r"..."` for anything with a colon
(the INI parser treats `:` as a separator).

The `[3code]` section picks the default profile. Override per-invocation
with `-p`:

    3code -p groq "refactor the http client"

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
