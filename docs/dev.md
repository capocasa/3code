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

## Regenerating

These pages are generated, never hand edited. The doc comment in the source
is the text; `nimble devdocs` rewrites `docs/dev/` from `src/`:

```
nimble devdocs
```

.. note:: The API here is internal. It serves readers of the source and
   embedders who accept churn; nothing on these pages is a compatibility
   promise.
