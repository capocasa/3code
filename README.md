# 3code

**The economical coding agent.**

Get more done with less!

Make your AI plan last longer, lower your token bill, program locally faster. Enjoy yourself more with instant startup and a calm interface. 

→ [3code.capocasa.dev](https://3code.capocasa.dev)

![3code](docs/3code-screen-1.png)

---

## Why

A coding agent that works with any OpenAI-compatible endpoint. Bring your own provider! Free-tier and local models work, and subscriptions will last much longer.

## Quickstart

```
# osx/linux
curl -fsSL https://3code.capocasa.dev/install | sh

# windows
irm https://3code.capocasa.dev/install.ps1 | iex

3code
```

First run walks you through adding a provider (name, URL, API key, models) and verifies with a test call.

## Manual

The full documentation is available

[https://3code.capocasa.dev/docs](https://3code.capocasa.dev/docs)


## Build from source

```
nimble install https://github.com/capocasa/3code
```

Requires [Nim](https://nim-lang.org) >= 2.0 and `curl` on `PATH`.

## Library

3code is also a Nim library: the same agent the CLI runs, embeddable in your own program with the terminal replaced by return values and callbacks. Sandbox, tool calls, session persistence, all of it. This is the foundation for building other coding agents or agents of any kind on top of 3code: a web frontend, a chat bot, a CI runner that fixes its own failures, an IDE plugin. The agent loop, tool use, and sandboxing are done; you bring the interface.

```nim
import threecode

let s = initAgentSession(AgentOptions(model: "deepinfra.deepseek-v3.2"))

# blocking: run a full turn (model calls + tool calls) and get the reply
let reply = s.prompt("what does this project do?")

# streaming: same call, events as they happen
s.onEvent = proc(ev: AgentEvent) =
  case ev.kind
  of aevDelta: stdout.write ev.text        # assistant text chunks
  of aevTool: stderr.writeLine ev.text     # tool results, notices
  of aevDone: echo ev.usage                # per-call token usage
  else: discard
discard s.prompt("run the tests and fix what breaks")

# colon commands work too
echo s.command(":tokens")

s.close()
```

`AgentOptions` mirrors the CLI flags: `model`, `cwd`, `resume`/`resumeId`, `sessionPath`, `experimental`, `debug`. `promptAsync` runs a turn on a library-managed thread if you'd rather not block your own. One live session per process; no async.

A working example lives in [`example/webserve.nim`](example/webserve.nim): a web frontend that serves a chat page, runs turns on a session thread, and streams replies to the browser over SSE. `nim c -r example/webserve.nim` and open http://localhost:8501.

## Changelog

**unreleased** - patient retry, single-file sandbox policy

- **Single-file sandbox policy.** The old two-level cascade is gone: exactly one policy file is active at a time, the repo `.sandbox` when it exists, else the user file `~/.config/3code/sandbox`, else the built-in default. 3code never creates the user file, so if you never configured anything you always get the current shipped default, not whatever default your first launch froze to disk; write `~/.config/3code/sandbox` yourself to change what every project without its own `.sandbox` gets. The first `:sandbox allow|readonly|deny` in a project materializes `.sandbox` from the effective policy, so project rules start from your baseline.
- **Patient retry.** Retryable API failures (429 usage limits, 5xx, network errors) now keep retrying on one shared exponential backoff capped at 2048s, for up to ~64 attempts (~36h), instead of surfacing after a short probe. A long-running session rides out a provider's rolling usage window or a network dropout (the train ride) without dropping back to the prompt. The underlying error message and attempt counter keep scrolling by as transcript lines so you can see what is being waited out. `:retry on|off` toggles it (default on; `off` keeps the ~1-minute initial ramp-up so transient blips still self-heal); persisted in `[settings]` as `patient_retry`. Ctrl-C cancels a running hold at any time.

**0.6.0** - filesystem sandbox backed by nimbox, folded into the `box` subcommand

- **Filesystem sandbox.** Every tool call is now confined to a one-line-per-rule policy (deny, read-only, writable). The effective policy is a cascade: a system file at `~/.config/3code/sandbox` then a repo file at `.sandbox`, each filling in for the one below with a safe built-in default (root denied, working directory writable) when absent, so the sandbox is always on without 3code ever writing a file into your project on first run. Bash commands get full kernel enforcement via `3code sandbox`, the built-in sandwall backend (Landlock on Linux, Seatbelt on macOS, a restricted-token ACL scheme on Windows) compiled in and re-execed in-process, so a write outside the allowed paths fails with `EACCES` at the syscall level. The read/write/patch tools check paths against the same policy in-process. On a host where the kernel backend can't restrict (a kernel without Landlock, a seccomp-filtered CI runner), bash degrades gracefully to unconfined while the in-process checks stay in force. `:sandbox show|on|off|allow|readonly|deny` edit and reload the policy live (`off` disables enforcement entirely); the agent never writes the file itself except to seed it on your first explicit `:sandbox` edit.

**0.5.1** - new providers, GLM-5.2 reasoning fixes, Qwen family

- **New providers and models.** OpenCode Zen + Go gateways, Kimi API Platform, Kimi Code subscription, nano-gpt, and `zaicode` (Z.ai coding endpoint). GLM-5.2, GLM-5.1, GLM-5, DeepSeek-V4 Pro/Flash, MiniMax-M3, Kimi K3/K2.7-code/K2.6, Qwen3.6/3.7, and Tencent Hy3 across these aggregators.
- **GLM-5.2 reasoning fixed.** Together and OpenRouter now actually send `reasoning_effort`/`reasoning.effort` for 5.2 (previously dropped silently); OpenRouter maps `max` to its native `xhigh`. A `variant` data bug that made GLM-5.2 collide with GLM-5.1 is corrected, so `:reasoning` offers the right `high`/`max` levels for every 5.2 entry, including third-party hosts.
- **Qwen family.** Qwen3.x is now a first-class family with its own reasoning wiring (vLLM `enable_thinking`), `:reasoning` surface, and prompt branch.
- **Provider config.** Adding a provider no longer treats a duplicate API key as a blocker, keys and URLs may be shared across providers, and a duplicate name gives a single clear error and returns to the prompt.
- **Internals.** `KnownGoodCombos` uses named field access instead of magic tuple indices, so adding a field can no longer silently shift every lookup.

**0.5.0** - Windows support, new providers, big stability push

- **Windows support.** MSYS2 bash is the supported shell; the bash tool, session locking, and color palette all work on Windows. Linux CI is split into amd64 and arm64; macOS gets its own fast build+publish workflow.
- **New providers and models.** Ollama, Eurouter, Lyceum, Regolo, and TensorX in the provider catalog, alongside MiniMax (M3, M2.7), Tencent Hunyuan (hy3 prompt family), Longcat, GLM-4.7-Flash (free z.ai MoE), and Novita. Refreshed DeepSeek, gpt-oss, Kimi, and GLM reasoning prompts and per-(provider, model) context windows.
- **Stable and reliable streaming.** Network-quiet hangs and truncated SSE streams now time out and retry instead of freezing forever. Empty model replies are recovered via finish_reason-aware turn handling. Bounded streaming recv makes the quiet-network timeout actually fire, including at provider-connect time, where `verifyProfile` now uses the bounded `streamhttp` client instead of the unbounded `httpclient` that could deadlock. ctrl-c cancels mid-stream, mid-tool, and during provider connect, with no leftover freeze or stale echo. The caret no longer flickers when the streaming repaint races the input thread; assistant prose and the bash tool viewport carry their inter-item gap during live streaming; and a spurious timing line no longer prints on a mid-stream interrupt.
- **Session resume and locking.** O(1) resume via a per-cwd session index; resume replays the full session into the scrollback. Stale session locks are reclaimed automatically and locking is atomic on Windows. A prompt draft survives an unexpected shutdown.
- **Terminal rendering fixes.** Redraw the fat prompt on resize without stacking chrome or drifting the prompt. Single-GUI-thread ownership of the composite frame; spinner and bar-tick merged into one renderer (kills a thread leak that froze the bottom row). Tool banners, plan glyphs, and receipts now share one byte-path renderer across live streaming and session replay, with the old alternate renderers and dead plan code removed. Correct display width for CJK, emoji, and combining marks; unicode (UTF-8) input in the editor. Light/dark tone auto-detected via OSC 11 background query, with `[settings] tone` and `[colors]` config overrides.
- **Bash tool.** Native timeout (no GNU `timeout` dependency, default 120s, ceiling 600s) and native `computeDiff` (no external `diff`). The model is told its own timeout. File contents shown for write-tool display.
- **Robustness.** Sanitize wire body so invalid UTF-8 can't brick a session; guard `computeDiff` against binary content; exit gracefully if the working directory is deleted mid-session; no silent exit on a broken stdout mid-turn. Network quiet timeout tightened from 180s to 45s.
- **Packaging.** `--version`/`3code -v` reports build provenance; nightly builds carry branch+commit in the version string.

**0.4.0** - error icons for failed tool calls, pin bar+prompt to bottom during scrolling, suppress raw JSON on malformed tool args

**0.3.5** - `$`/`r`/`w` tool bullets, bright cyan receipts, bar ticks during tool execution

**0.3.4** - initial docs site, `-i`/`--interactive` flag, streaming ping test

**0.3.3** - icon-based tool banners, history fixes, display polish

**0.3.2** - native read command, binary guard for bash, deepseek in known-good

**0.3.1** - `update_plan` tool, gpt-oss reasoning tuning

**0.3.0** - `--good` subcommand, ctrl-c cancel during stream, linux-arm64 builds

**0.2.7** - inline receipts, gpt-oss grounding prompts

**0.2.5** - token bar with cache indicator, skill autoloader, web-research trigger

**0.2.1** - per-model tool dispatch, multiline input, markdown table fit

**0.2.0** - initial public release

## Contributing

Patches welcome at [github.com/capocasa/3code](https://github.com/capocasa/3code).

- **Known-good provider/model pairs** with test results
- **Bug fixes** with a clear reproduction case

Bug reports welcome, but make sure you give enough specific information to reproduce the issue.

## License

MIT.
