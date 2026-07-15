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

## Changelog

**0.5.0** - Windows support, new providers, big stability push

- **Windows support.** MSYS2 bash is the supported shell; the bash tool, session locking, and color palette all work on Windows. Linux CI is split into amd64 and arm64; macOS gets its own fast build+publish workflow.
- **New providers and models.** Ollama, Eurouter, Lyceum, Regolo, and TensorX in the provider catalog, alongside MiniMax (M3, M2.7), Tencent Hunyuan (hy3 prompt family), Longcat, GLM-4.7-Flash (free z.ai MoE), and Novita. Refreshed DeepSeek, gpt-oss, Kimi, and GLM reasoning prompts and per-(provider, model) context windows.
- **Stable and reliable streaming.** Network-quiet hangs and truncated SSE streams now time out and retry instead of freezing forever. Empty model replies are recovered via finish_reason-aware turn handling. Bounded streaming recv makes the quiet-network timeout actually fire, including at provider-connect time, where `verifyProfile` now uses the bounded `streamhttp` client instead of the unbounded `httpclient` that could deadlock. ctrl-c cancels mid-stream, mid-tool, and during provider connect, with no leftover freeze or stale echo. The caret no longer flickers when the streaming repaint races the input thread; assistant prose and the bash tool viewport carry their inter-item gap during live streaming; and a spurious timing line no longer prints on a mid-stream interrupt.
- **Session resume and locking.** O(1) resume via a per-cwd session index; resume replays the full session into the scrollback. Stale session locks are reclaimed automatically and locking is atomic on Windows. A prompt draft survives an unexpected shutdown.
- **Terminal rendering fixes.** Redraw the fat prompt on resize without stacking chrome or drifting the prompt. Single-GUI-thread ownership of the composite frame; spinner and bar-tick merged into one renderer (kills a thread leak that froze the bottom row). Tool banners, plan glyphs, and receipts now share one byte-path renderer across live streaming and session replay, with the old alternate renderers and dead plan code removed. Correct display width for CJK, emoji, and combining marks; unicode (UTF-8) input in the editor. Light/dark color mode auto-detected via OSC 11 background query, with `[settings] mode` and `[colors]` config overrides.
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
