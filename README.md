# 3code

**The economical coding agent.**

Does 5× more work for the same tokens. Your subscription lasts longer. Free-tier models actually work.

→ [3code.capocasa.dev](https://3code.capocasa.dev)

![3code](docs/3code-screen-1.png)

---

## Why

Claude Code, Cursor, Copilot — they all optimize for capability. Nobody optimizes for **cost**. 3code is the only coding agent that treats your token budget as a first-class constraint.

That means your $20 subscription lasts a month instead of a week. It means you can use DeepSeek V4 or GLM-5.2 free tier and still get real work done. It means you don't have to think twice before asking a question.

Works with any OpenAI-compatible endpoint. Bring your own provider — free tiers, flat-rate coding plans, subscriptions, and local servers all work.

## Data to back it up

SWE-bench Verified, 10-task subset — five agents through the same LiteLLM proxy on Z.ai GLM-5.3, same provider, same 600s per-task cap, vanilla configs. Every difference in the results is the harness, not the model:

| agent | total tokens | % of median | resolved |
|---|---|---|---|
| **3code** | **4,209,360** | **88.3%** | **7/10** |
| pi | 4,641,357 | 97.4% | 6/10 |
| zcode | 4,766,000 | 100.0% | 6/10 |
| hermes | 6,072,610 | 127.4% | 6/10 |
| opencode | 6,771,747 | 142.1% | 6/10 |

3code used 9% fewer tokens than pi and resolved one more task. Output tokens are the starkest gap: 71,751 for 3code vs 117,707 for pi — a 1.6× difference, and on a pay-per-token API that's money on every single turn.

An earlier round on GLM-5.2 against opencode alone: 3code used 75% fewer tokens and resolved a task opencode failed. Full per-task data and methodology → [3code.capocasa.dev/swe](https://3code.capocasa.dev/swe/3code-benchmark-10-glm53.html)

## How it pulls it off

- **Chunked mode** — constantly extracts relevant context and discards what's stale. Keeps the agent sharp without carrying dead weight, and *improves* results because of intelligent discarding.
- **Aggressive caching** — covers all bases; every cache hit is money saved.
- **Context compaction** — supersede-aware: later writes elide stale reads, shrinking context automatically.
- **Self-clearing execution** — plan/execute skill resets context between phases for larger tasks. No context bloat.

We eat our own dog food — 3code is now written entirely with 3code, using GLM 5.2 on Z.ai's free tier.

## Install

```
# macOS / Linux
curl -fsSL https://3code.capocasa.dev/install | sh

# Windows (PowerShell)
irm https://3code.capocasa.dev/install.ps1 | iex

# Termux on Android arm64
pkg install curl && curl -fsSL https://3code.capocasa.dev/install | sh
```

The Termux build runs on your phone: the installer detects `$PREFIX` and drops the binary in `$PREFIX/bin`. Android has no OS sandbox, but the in-process path checks still apply. Details in the [manual](https://3code.capocasa.dev/docs#termux-on-android-arm64).

## Quickstart

1. Get an API key from [build.nvidia.com](https://build.nvidia.com). NVIDIA
   Build has a free tier with several known-good coding models, no payment
   required, which makes it the recommended way to try 3code for the first
   time.
2. Run `3code` in a project directory. With no provider configured, the
   setup wizard starts by itself.
3. At the first prompt, enter `nvidia` and paste your key.
4. Pick a model from the list. `glm-5.3-flash` and `deepseek-v4-flash` are solid defaults.
5. Type a prompt:

```
❯ Write a Hello World in Nim and run it
```

That's it. When the free tier runs out, run `:provider add` to stack
another. The [provider guide](https://3code.capocasa.dev/docs#providers-and-authentication)
covers free tiers, flat-rate coding plans, subscription logins, and local
servers.

## Technical details

- **1.6 MB binary** — single executable, no runtime dependencies
- **Cross-platform** — Linux x86-64/arm64 · macOS universal · Windows · Termux (Android arm64)
- **No daemon, no web UI** — run it, use it, done
- **Instant startup** — loads and responds instantly; your agent should never keep you waiting
- **40 known-good combos** — validated provider + model pairings, just works out of the box
- **Loop guard** — detects runaway autonomous edits, halts at configurable thresholds
- **Session persistence** — human-readable `.3log` format; resume any past session
- **Native web search** — built-in, no curl dependency
- **No telemetry** — sessions stay local, nothing phoned home
- **MIT license** — do whatever you want with it

## Library

3code is also a Nim library: the same agent the CLI runs, embeddable in your own program with the terminal replaced by return values and callbacks. Sandbox, tool calls, session persistence, all of it. Build a web frontend, a chat bot, a CI runner that fixes its own failures, an IDE plugin — the agent loop, tool use, and sandboxing are done; you bring the interface.

The programming manual, with examples and API details, lives in the [docs](https://3code.capocasa.dev/docs).

## Contributing

Patches welcome! Open an issue, send a PR, or just try the bleeding edge and report back:

```
# macOS / Linux
curl -fsSL https://3code.capocasa.dev/main/install | sh

# Windows (PowerShell)
irm https://3code.capocasa.dev/main/install.ps1 | iex
```

## License

MIT.
