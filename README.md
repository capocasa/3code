# 3code

**The economical coding agent.**

Get more done with less!

Make your AI plan last longer, lower your token bill, program locally faster. Enjoy yourself more with instant startup and a calm interface.

→ [3code.capocasa.dev](https://3code.capocasa.dev)

![3code](docs/3code-screen-1.png)

---

## Why

A coding agent that works with any OpenAI-compatible endpoint. Bring your own provider! Free-tier and local models work, and subscriptions will last much longer.

## Install

```
# macOS / Linux
curl -fsSL https://3code.capocasa.dev/install | sh

# Windows (PowerShell)
irm https://3code.capocasa.dev/install.ps1 | iex
```

## Get started in five minutes

1. Get an API key from [build.nvidia.com](https://build.nvidia.com). NVIDIA
   Build has a free tier with several known-good coding models, no payment
   required, which makes it the recommended way to try 3code for the first
   time.
2. Run `3code` in a project directory. With no provider configured, the
   setup wizard starts by itself.
3. At the first prompt, enter `nvidia` and paste your key.
4. Pick a model from the list. `glm-5.2` is a solid default.
5. Type a prompt:

```
❯ Write a Hello World in Nim and run it
```

That's it. When the free tier runs out, run `:provider add` to stack
another. The [provider guide](https://3code.capocasa.dev/docs#providers-and-authentication)
covers free tiers, flat-rate coding plans, subscription logins, and local
servers.

## Manual

The full documentation is at [3code.capocasa.dev/docs](https://3code.capocasa.dev/docs):
providers, configuration, sandbox policies, sessions, colon commands, and
building from source.

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

See [CHANGELOG.md](CHANGELOG.md).

## Contributing

Patches welcome at [github.com/capocasa/3code](https://github.com/capocasa/3code).

- **Known-good provider/model pairs** with test results
- **Bug fixes** with a clear reproduction case

Bug reports welcome, but make sure you give enough specific information to reproduce the issue.

## License

MIT.
