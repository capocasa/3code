# 3code

**The economical coding agent.**

It's so lean you can use it for free.

→ [3code.capocasa.dev](https://3code.capocasa.dev)

---

## Why

A coding agent that works with any OpenAI-compatible endpoint. Bring your own provider, pay for the work, not the chatter. Free-tier models work. No subscription required.

## Quickstart

```
curl -fsSL https://3code.capocasa.dev/install | sh
3code
```

First run walks you through adding a provider (name, URL, API key, models) and verifies with a test call. Then:

```
3code "add a --dry-run flag to the main command"
```

Or drop into interactive mode and go.

## Build from source

```
nimble install https://github.com/capocasa/3code
```

Requires [Nim](https://nim-lang.org) >= 2.0 and `curl` on `PATH`.

## Docs

Full manual at [3code.capocasa.dev](https://3code.capocasa.dev). Developer docs via `nimble devdocs`.

## Changelog

**0.4.1** - light/dark color mode (auto from `$COLORFGBG`, `--light`/`--dark`, `[colors]` config overrides)

**0.4.0** — error icons for failed tool calls, pin bar+prompt to bottom during scrolling, suppress raw JSON on malformed tool args

**0.3.5** — `$`/`r`/`w` tool bullets, bright cyan receipts, bar ticks during tool execution

**0.3.4** — initial docs site, `-i`/`--interactive` flag, streaming ping test

**0.3.3** — icon-based tool banners, history fixes, display polish

**0.3.2** — native read command, binary guard for bash, deepseek in known-good

**0.3.1** — `update_plan` tool, gpt-oss reasoning tuning

**0.3.0** — `--good` subcommand, ctrl-c cancel during stream, linux-arm64 builds

**0.2.7** — inline receipts, gpt-oss grounding prompts

**0.2.5** — token bar with cache indicator, skill autoloader, web-research trigger

**0.2.1** — per-model tool dispatch, multiline input, markdown table fit

**0.2.0** — initial public release

## Contributing

Patches welcome at [github.com/capocasa/3code](https://github.com/capocasa/3code).

- **Known-good provider/model pairs** with test results
- **Bug fixes** with a clear reproduction case

Bug reports welcome, but make sure you give enough specific information to reproduce the issue.

## License

MIT.
