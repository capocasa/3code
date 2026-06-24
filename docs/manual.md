.. title:: 3code - the economical coding agent

## Introduction

3code exists because I needed a coding agent to fill the gap between whatever
the main American shops are offering and my day-to-day need for reliability.
The main shops just don't deliver on reliability; there's always *something*
going on.

3code takes a bare-bones "works right now" approach where everything is geared
toward maximal value right now and minimal cost. No splurging because we're
making a bet things will be cheaper tomorrow, no needing to deliver splurgy
unnecessarily fancy features to keep up appearances.

There are a few simpler offerings but they each had a few issues I just barely
found enough to want to build my own.

## Quickstart

### Get a provider

Sign up at one of the supported providers and get an API key:

- `nvidia <https://build.nvidia.com>`_ - free tier, gpt-oss-120b, good for
  most tasks
- `z.ai <https://z.ai/>`_ - GLM 5.1 coding plan, excellent quality,
  affordable flat rate
- `deepinfra <https://deepinfra.com/>`_ - pay-per-token, reliable, broad
  model selection

### Install

```
# macOS / Linux
curl -fsSL https://3code.capocasa.dev/install | sh

# Windows (PowerShell)
irm https://3code.capocasa.dev/install.ps1 | iex
```

### Enter your API key

Navigate to your project directory and run `3code`. On first launch with no
config it walks you through setup:

```
  ╶──╮
  ╶──┤    3code v0.3.4   the economical coding agent
  ╶──╯

  no provider configured. let's add one. (ctrl+d to quit)
  supported: deepinfra, ovh, nvidia, nebius, fireworks

  api key              : ************************
  provider name or url : nvidia
  verifying... ok
  saved to ~/.config/3code/config
```

### Run your first prompt

```
❯ Build me a Hello World program in Nim
```

## Picking a provider

There are two categories of provider that are interesting to use with 3code:
the nvidia free tier and Chinese flat-rate providers. Other providers work but
will most likely be too expensive except to test-drive different models.

`nvidia <https://build.nvidia.com>`_ - Free tier. You get gpt-oss-120b, which
is good enough for a lot of cases. You will notice when it starts to get
limiting. MiniMax M2.7 is a very modern option on nvidia but it is pretty slow,
something you want to use in the background.

`z.ai <https://z.ai/>`_ - GLM 5.1 on the z.ai coding plan is my provider of
choice. Privacy and jurisdiction is not an issue because all code is open
source and hence public. Excellent quality at an affordable flat rate.

`OVH <https://endpoints.ai.cloud.ovh.net/>`_ - An interesting EU-resident
choice: gpt-oss on pay-per-token, cheap enough, and great if you need EU
ownership and data.

Add a provider inside the REPL:

```
:provider add
```

Or switch between configured providers:

```
:provider use nvidia
:provider use zai.glm-5.1
```

## Starting programming

Use the `:model` command (tab-complete it), then press Tab again to rotate
through all the models configured for the current provider.

Then tell the model what you want.

I like to keep a `3CODE.md` in the project root that inlines my main project
style file with a `@../3CODE.md` reference. `AGENTS.md` also works; I prefer
agent-specific filenames.

## Usage monitoring

Every response shows a token receipt on its own line:

```
  ○12%  ↑4.2k  ↻18k  ↓1.1k  8s
```

The fields:

| glyph | meaning |
|-------|---------|
| `○N%` | context window used (percentage) |
| `↑`   | fresh input tokens (not cached) |
| `↻`   | cached input tokens |
| `↓`   | output tokens generated |
| `Xs`  | wall-clock seconds for this response |

During streaming, the same line updates live so you can watch the numbers tick
up in real time. If a glyph is absent it just means the provider did not stream
that information.

## Thinking

When a model reasons before replying, its thinking is shown as a one-line
ticker above the spinner. This gives you a quick sense of what the model is
working through without flooding the screen.

To toggle it:

```
:think off
:think on
```

The ticker has no effect if the provider does not emit reasoning content.

## Known good models

These provider/model pairs have been tested to give fairly consistent results.
Tokens can still be burnt on errors - that is part of the game.

**GLM (ZAI)**

| provider   | model         | notes              |
|------------|---------------|--------------------|
| zai        | glm-5.1       | recommended        |
| zai        | glm-5         |                    |
| zai        | glm-5-turbo   | faster             |
| zai        | glm-4.7       |                    |
| zaicode    | glm-5.1       | coding plan        |
| fireworks  | glm-5.1       |                    |
| together   | glm-5.1       |                    |
| deepinfra  | glm-5.1       |                    |
| nebius     | glm-5         |                    |
| nvidia     | glm-4.7       |                    |

**gpt-oss (Microsoft)**

| provider   | model             | notes          |
|------------|-------------------|----------------|
| nvidia     | gpt-oss-120b      | free tier      |
| ovh        | gpt-oss-120b      | EU             |
| groq        | gpt-oss-120b     |                |
| nebius     | gpt-oss-120b      |                |
| sambanova  | gpt-oss-120b      |                |
| deepinfra  | gpt-oss-120b      |                |

**DeepSeek**

| provider   | model             | notes          |
|------------|-------------------|----------------|
| deepseek   | deepseek-chat     | v3             |
| deepseek   | deepseek-reasoner | r1             |
| deepseek   | deepseek-v4-pro   |                |
| nebius     | deepseek-v3.2     |                |
| nebius     | deepseek-v4-pro   |                |
| together   | deepseek-v4-pro   |                |
| deepinfra  | deepseek-v4-pro   |                |
| sambanova  | deepseek-v3.2     |                |

**MiniMax**

| provider   | model          | notes      |
|------------|----------------|------------|
| nvidia     | minimax-m2.7   |            |
| nvidia     | minimax-m2.5   |            |
| fireworks  | minimax-m2.7   |            |
| together   | minimax-m2.7   |            |
| sambanova  | minimax-m2.7   |            |
| deepinfra  | minimax-m2.5   |            |

**Kimi**

| provider   | model     | notes |
|------------|-----------|-------|
| together   | kimi-k2.6 |       |
| fireworks  | kimi-k2.6 |       |
| deepinfra  | kimi-k2.6 |       |
| together   | kimi-k2.5 |       |

Note: Qwen just barely did not make it into the known-good list but testing
continues.

To see the current list at any time:

```
3code --good
```

## Experimental mode

Experimental mode unlocks any model from any provider. Any token burn from
untested combinations is on you.

```
3code --experimental
# or
3code -x
```

Known-good models have preset tuning parameters (temperature, reasoning effort,
max tokens). In experimental mode you can also control reasoning level and
temperature directly:

```
:reasoning low
:reasoning medium
:reasoning high
```

## Resume

Resume the most recent session in the current directory:

```
3code --resume
# or
3code -r
```

List recent sessions for the current directory (newest first, up to 20):

```
3code --list
# or
3code -l
```

Listing is scoped to the current directory by design. To see every saved
session, run 3code from the sessions directory itself (e.g.
`~/.local/share/3code/sessions`).

Resume a specific session by ID:

```
3code --resume=abc123
```

Note: different providers expire their prompt cache at different rates. Resuming
an old session still works but you will not get cache savings on stale context.

## Context clear

Inside the REPL, `:clear` wipes the accumulated context and starts a fresh
conversation with the same provider and model. Useful when a task is done and
you want to start something new without the old context bleeding in.

```
:clear
```

## Chunked mode

For larger tasks, have the model create a plan first and divide the work into
natural chunks - each saved to a file. Each chunk file should end by calling
the `context_clear` tool with the next file as the parameter. This produces
a series of implementing steps with context resets in between.

Example prompt to kick off a chunked task:

```
Divide the following task into 4-6 chunks, each in its own impl-N.md file.
End each file by calling context_clear with instructions to read the next file.
Then execute chunk 1.

Task: add comprehensive test coverage to the parser module.
```

3code's built-in `task-chunked-implementation` skill documents the exact
workflow. Invoke it with:

```
use the chunked implementation skill: <task description>
```

Chunked mode is well-suited to busywork that does not require human interaction,
such as adding basic test coverage across a large codebase. A capable model is
needed; GLM 5.1 works well.

Calling `context_clear` at the end of each chunk with the next file as the
target also serves as a cheap capability test: if the model loses track enough
to forget to call the next file, the task was probably too hard for this mode.

**Chunked mode is not agent orchestration.** There is no spawning of sub-agents,
no parallel execution, no shared state bus. It is one model, one session at a
time, handing off context via a tool call. This is intentional: agent
orchestration is expensive to program, expensive to reason about, and current
approaches do not seem to result in token savings. That is the opposite of
economical.

This stance may be revised as agent orchestration knowledge matures.

## Developments

3code will keep up with the "works right now" approach as agentic coding
develops.

We will continue to support more models and providers as they come out.

## Contributing

Developer documentation (module graph, proc docs, type definitions) is in
`docs/dev/threecode.html`. Build it with `nimble devdocs`.

Pull requests welcome:

- known-good provider/model pairs with test results
- bug fixes with a clear reproduction case

Bug reports welcome, but make sure you give enough specific information to
reproduce the issue. If you are not sure what that means, please find out before
reporting - if in doubt, ask your own 3code how to do that.

## Prior art

3code is heavily influenced by Claude Code, goose, pi, and codex. While I like
the particular tradeoffs better, imitation is the sincerest form of flattery and
3code should be looked at as heavily inspired by them. As a European, I still
think using Claude Code feels like driving a turbocharged Ford F-150 to buy a
pack of gum, but I still love you.

Having said that, 3code deliberately chose to forgo some features they have,
just to focus on the task of writing software as effectively, reliably, and
consuming as few resources as possible.
