.. title:: 3code - developer docs

.. raw:: html

  <div class="dev-kicker">developer docs</div>

## Introduction

These are the developer docs: the internal API of 3code as extracted from
the source by `nim doc`, every module, type, and proc with its doc comment.
Where the [manual](index.html) shows you how to use the app and the
[reference](reference.html) lists every switch and config key, this half is
for people embedding 3code in another program, writing a plugin, or
changing 3code itself.

Start from the entry points:

- [threecode](dev/threecode.html) - the root module: entry point, outer
  REPL loop, and the full module list
- [index of every symbol](dev/theindex.html) - flat, alphabetical, one page

## Embedding

The headless frontend is `threecode/library`: it runs the same agent loop,
tools, sandbox, and `.3log` sessions as the CLI, with the terminal replaced
by return values and callbacks.

```nim
import threecode/library

let s = initAgentSession(AgentOptions(model: "deepinfra.deepseek-v3.2"))
echo s.prompt("what does this project do?")
s.close()
```

## Module tour

The modules a host or contributor touches most, with their job in one line:

| module | what lives there |
| --- | --- |
| [turns](dev/threecode/turns.html) | turn lifecycle orchestration |
| [actions](dev/threecode/actions.html) | tool dispatch: model tool_call JSON into Actions, then execute |
| [snap](dev/threecode/snap.html) | goal-mode tree manifest: arm at the mode, re-walk after bash, fold shell mutations into the change log |
| [api](dev/threecode/api.html) | HTTP client and SSE parsing |
| [session](dev/threecode/session.html) | session persistence in the `.3log` format |
| [config](dev/threecode/config.html) | config file parsing and provider/profile resolution |
| [types](dev/threecode/types.html) | shared types and process-level globals |
| [engine](dev/threecode/engine.html) | stateful terminal layout engine |
| [minline](dev/threecode/minline.html) | multiline line editor |
| [display](dev/threecode/display.html) | transcript formatting: markdown, receipts, banners |
| [web](dev/threecode/web.html) | fetch and search helpers exposed as native tools |

The root module's list also carries the newer surfaces (`library` for
embedding, the plugin ABI, the sandbox and ACP frontends) and the long tail
of wire translations, auth flows, and terminal internals.

## Development guidelines

Rules that keep the interactive front ends responsive. They bind every
change that adds or touches a `:` command.

### A system command must never block

A `:` command runs while the user waits at the prompt (or queued behind a
running turn), so it must return immediately — no network call, no model
call, no long local work on the controller or input thread. Anything
slower than a file read or a config write runs on a separate thread, and
its result is delivered asynchronously afterwards, exactly like a normal
one: the answer is committed to scrollback whenever it lands, and the
tokens it burned are added to the session ledger and the token bar (the
sum of both requests), not dropped because the call was async.

`:btw` is the pattern (see `btwthread.nim`): the command builds its
request from the live history on the controller thread (the only place
the history is stable), hands plain strings to a worker, and answers
with no body of its own: the controller commits the `?`-led question
item in place of the echoed command line. The controller polls the job from its input wait
(`ui.deliverFinishedBtw`) and commits the answer — dim, under the
aside's `!` icon, beneath the `?` question item that replaced the echoed
command line — between keystrokes. The worker's wire policy
(`btwRequest`) is the main transport's in miniature: 429/5xx/transport
failures and an empty 200 back off and retry, and an interrupt cancels
the aside by comparing `interruptsSeen()` counts (the flag itself is
cleared when the next turn starts); a cancelled worker's blocked HTTP
call runs out on the retired list so later answers never queue behind
it. Synchronous-by-contract surfaces (the
library's `command()`) are the one exception: they join the worker and
fold the answer into their return value, because their whole API blocks
by design.

## Regenerating

These pages are generated, never hand edited. The doc comment in the source
is the text; `nimble devdocs` rewrites `docs/dev/` from `src/`:

```
nimble devdocs
```

.. note:: The API here is internal. It serves readers of the source and
   embedders who accept churn; nothing on these pages is a compatibility
   promise.
