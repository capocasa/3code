# 3code

**The economical coding agent.**

Saves tokens, brain cycles, computer power, and your privacy.

→ [3code.capocasa.dev](https://3code.capocasa.dev)

![3code](docs/3code-screen-1.png)

---

## Reliable AI-assisted programming

Compared to coding by hand, AI-assisted coding can be a lot less independent. You're buying from a provider, who will have:

- outages
- rate limits
- data uploading
- unnecessary token consumption
- unpredictable quality

The usual remedy for any unpredictable system is redundancy: one stops working, the next kicks in. But if you're running a provider's ecosystem, you can't do that. They do everything they can to make switching harder.

That's why I made 3code. It's a free and open source AI-assisted coding agent that:

- is totally trustworthy: free and open source
- does not subscribe to the "tokenmaxxing" philosophy: careful with spending
- is a fully command line program: respects your scrollback
- is tiny and uses very little resources: compiled single binary
- goes where you go: cross platform
- is convenient but powerful: prompt and it will just keep going
- has unique token-saving features: chunked mode and cybernetic mode split tasks serially, keeping context low

As a heavy command-line and no-chrome tiling window manager user, everything else feels like a noisy token burner that's going to run away with my data at any time.

## Get started

**1. Get a provider.**

| provider | model | |
|---|---|---|
| [opencode](https://opencode.ai/) | deepseek | free deepseek agentic coding |
| [z.ai coding plan](https://z.ai/) | glm-5.3 | the economical coding plan, used to develop 3code |
| [tensorx](https://tensorx.ai) | glm-5.3 | EU-native |

Or use your existing subscription:

| provider | model | |
|---|---|---|
| [supergrok](https://x.ai) | grok | comes with an X pro account |
| [antigravity](https://antigravity.google) | gemini | comes with a google account |
| [chatgpt](https://chatgpt.com) | gpt | use an existing chatgpt pro account |

Also supported: moonshot's Kimi (subscriptions and API), Deepseek, OpenRouter, and many others. The [provider guide](https://3code.capocasa.dev/docs#known-good-models) has the full list.

Tip: you can use expensive models on small subscriptions with 3code. Leave the task and it will continue automatically when your 5h window resets.

**2. Install 3code and enter your API key.**

```
# macOS / Linux
curl -fsSL https://3code.capocasa.dev/install | sh

# Windows (PowerShell)
irm https://3code.capocasa.dev/install.ps1 | iex

# Termux on Android arm64
pkg install curl && curl -fsSL https://3code.capocasa.dev/install | sh
```

```
$ mkdir myprojectdir
$ cd myprojectdir
$ 3code
```

With no provider configured, the setup wizard starts by itself. Enter a provider name or URL, paste your key, done.

On Windows the PowerShell installer also fetches a private MSYS2 tree (bash
+ unix tools) under `%LOCALAPPDATA%\3code`. If you already run
[Git for Windows](https://git-scm.com/download/win), you can skip that:
unpack `3code-windows-amd64.zip` from the
[releases page](https://github.com/capocasa/3code/releases/latest) anywhere and
3code uses Git's bash. Details in the
[manual](https://3code.capocasa.dev/docs#manual-install-on-windows).

The Termux build runs on your phone: the installer detects `$PREFIX` and drops the binary in `$PREFIX/bin`. Android has no OS sandbox, but the in-process path checks still apply. Details in the [manual](https://3code.capocasa.dev/docs#termux-on-android-arm64).

**3. Run your first prompt.**

```
❯ Build me a Hello World program in Nim
```

That's it. When the free tier runs out, run `:provider add` to stack another.

## The 3 in 3code

The 3 in 3code is *third-party*: your coding agent doesn't have to come from the company that sells you your models. Any provider, any model, and if yours starts doing unreliable things you switch providers instantly, without friction, and get back to coding. The 3 is also the three E's the design hangs on:

- **Token efficiency.** Your bills are lower and your plan lasts longer. Free-tier tokens do real work, and you stop thinking twice before asking. Nothing else about your setup has to change: just swap the agent.
- **Computer efficiency.** No lap burn, longer battery life, and a machine that stays snappy even with dozens of agents running side by side.
- **Ergonomics.** No distractions, no gimmicks, and a learning curve so low you are productive in minutes. You stay focused, so more of what you build actually works.

## Community

The forum is open at [community.3code.capocasa.dev](https://community.3code.capocasa.dev/). Install help is available there, along with everything else: questions, frustrations, tips, or anything you made with 3code.

The spirit of the place, straight from the welcome thread: create software in the best possible way, with common sense and without fear or doubt. Tokens are what it takes to write code now, so use as few as you can. The docs are an ever growing list of how to get things done, and tips land on the forum now and then. Two rules only: stay on topic (making good use of 3code, and its development) and be nice. Self promotion is fine, show us what you made.

## Data to back it up

Testing token performance properly is really hard and expensive. I'm running preliminary tests that involve a 10-task subset of SWE-bench. While this is far from perfect, it does show an interesting ballpark comparison of different coding agents. 3code is doing pretty good!

SWE-bench Verified, 10-task subset, five agents through the same LiteLLM proxy on Z.ai GLM-5.3, same 600s per-task cap, vanilla configs:

| agent | total tokens | resolved |
|---|---|---|
| **3code** | **4,209,360** | **7/10** |
| pi | 4,641,357 | 6/10 |
| zcode | 4,766,000 | 6/10 |
| hermes | 6,072,610 | 6/10 |
| opencode | 6,771,747 | 6/10 |

3code used 9% fewer tokens than pi and resolved one more task. Output tokens are the starkest gap: 71,751 for 3code vs 117,707 for pi, a 1.6× difference, and on a pay-per-token API that's money on every single turn.

Rerun on the same 10 tasks, GLM-5.3, six agents including Claude Code, rows ordered by total token use (prompt + output, cache-inclusive):

| agent | total tokens | resolved |
|---|---|---|
| **3code** | **5.1M** | **9/10** |
| pi | 7.2M | 6/10 |
| opencode | 10.0M | 9/10 |
| zcode | 14.2M | 6/10 |
| hermes | 16.8M | 7/10 |
| claude | 23.1M | 8/10 |

Every agent hit 93-99% context-cache reads on the Z.ai coding plan, so spend tracks context volume: Claude Code processed 4.6× 3code's tokens to resolve one fewer task. 3code and opencode tie at 9/10, with 3code doing it at half the tokens. See the [full report, grid and methodology](https://3code.capocasa.dev/swe/glm53-rerun.html).

An earlier round on GLM-5.2 against opencode alone: 3code used 75% fewer tokens, a 4× saving, and resolved a task opencode failed, with zero eval errors and zero unresolved patches. Details in the [blog post](https://capocasa.dev/3code-benches-75-lower-token-use-vs-opencode-on-10-task-swe-bench-subset.html), with [full per-task data and methodology](https://3code.capocasa.dev/swe/3code-benchmark-10-glm53.html) and the [GLM-5.2 round](https://3code.capocasa.dev/swe/3code-benchmark-10-1.html).

## Technical details

- **~6 MB binary** - single executable, no runtime dependencies
- **Cross-platform** - Linux x86-64/arm64 · macOS universal · Windows · Termux (Android arm64)
- **No daemon, no web UI** - run it, use it, done
- **Low visual noise** - high information density; terse output, nothing wasted
- **800+ known-good combos** - validated provider + model pairings, just works out of the box
- **Loop guard** - detects runaway autonomous edits, halts at configurable thresholds
- **Session persistence** - human-readable `.3log` format; resume any past session
- **Native web search** - built-in, no curl dependency
- **Context clear tool** - wipe accumulated context mid-session to start a subtask fresh
- **Self-clearing execution** - plan/execute skill resets context between phases for larger tasks
- **No telemetry** - sessions stay local, nothing phoned home
- **MIT license** - do whatever you want with it

## Library

3code is also a Nim library: the same agent the CLI runs, embeddable in your own program with the terminal replaced by return values and callbacks. Sandbox, tool calls, session persistence, all of it. Build a web frontend, a chat bot, a CI runner that fixes its own failures, an IDE plugin; the agent loop, tool use, and sandboxing are done, you bring the interface.

The programming manual, with examples and API details, lives in the [docs](https://3code.capocasa.dev/docs). The dry inventory of every config key, CLI switch, and `:` command is the [reference](https://3code.capocasa.dev/reference.html).

## 3code enterprise

3code makes a subscription last five times longer. That saving compounds across a team. I can make it happen in your company: central providers, model control, spending limits. Same agent your engineers already want to use, rolled out as a team tool.

→ [Schedule a call](https://3code.capocasa.dev/schedule-call.html)

## Contributing

Patches welcome! Open an issue, send a PR, or just try the bleeding edge and report back:

```
# macOS / Linux
curl -fsSL https://3code.capocasa.dev/main/install | sh

# Windows (PowerShell)
irm https://3code.capocasa.dev/main/install.ps1 | iex
```

## License

MIT

## Trademark

3code™ is a trade mark owned by Carlo Capocasa. Registration pending.

https://euipo.europa.eu/eSearch/#details/trademarks/019415437
