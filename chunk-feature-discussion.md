# Chunked Execution Feature Discussion

## Context

The existing `context_clear(summary, instructions)` tool wipes all conversation history except the system prompt, then injects a single user message. The chunked-implementation skill works around this by writing plan files to disk and passing "read impl-N.md" as instructions — disk is the memory between chunks.

The goal: make multi-chunk execution semi-automatic. Not a full orchestrator — just remove the manual steps of "read next file, call clear, start fresh."

## What we explored

### Auto-read (shelved)

Idea: automatically detect file paths in user messages and pre-load file contents into context, saving the model a turn.

Pros: saves turns on every file reference. Cons: can't distinguish "read this now" from "this file exists for reference." Skills are conditional reads — the agent decides when to load them. Auto-read would break that. Too much complexity for the benefit. See `ideas.md`.

### File-based shared context (simplified away)

Idea: `context_clear` takes a list of files to pre-load, giving API providers a stable prefix to cache. Evolved into `@file` syntax, then duck-typed path detection, then auto-read on every message. All overengineered. The chunk files already handle this — they list what to read.

### Orchestrator with failure detection (rejected)

Researched how Symphony (OpenAI), Praetorian, and others handle sub-agent success/failure. They all use deterministic validation (build checks, file existence, CI results) rather than interpreting model output. Good for production orchestrators — too complex for 3code. The user manually verified each chunk and that worked fine. We're automating the mechanical steps, not building an orchestrator.

### Trust-based naive chain (current approach)

The key insight: this is semi-automatic execution, not orchestration. Only use it with models you already trust from manual runs. No verification, no retry logic, no success grading. The model either does the work or it doesn't.

## What we settled on

### Rename: `context_clear` → `clear`

Mirrors the CLI command. Short, obvious. The tool clears context.

### Add `next_file` parameter to `clear`

- `clear(summary, instructions)` — existing behavior, works as before
- `clear(next_file: "impl-2.md")` — new: verify file exists, clear context, load file contents as user message
- `clear()` with no params — clear context, end session / return to interactive

### File existence check as trust signal

If the model calls `clear(next_file: "impl-3.md")` and the file doesn't exist → error, stop, display to user. The model producing a valid filename is a real, checkable claim. Getting it wrong means the model has lost the plot — exactly when you'd want to stop.

### Planner drives the chain

The planner (via skill instructions) writes each chunk file with a `clear(next_file: ...)` call at the end, except the last file which omits it. The model is a coding model — writing a correct filename into a text file is baseline competence.

No `run_chain` tool, no glob, no orchestration loop. The model calls `clear` like any other tool. The system just validates the filename.

### Skill update

The chunked-implementation skill gets updated instructions:
- Rename all `context_clear` references to `clear`
- Each chunk file except the last ends with: "When done, call clear(next_file: impl-N.md)"
- Last chunk omits the clear call

### `shared_context` string (deferred)

A persistent string set on first clear and inherited across subsequent clears. Good idea but not needed for v1. The chunk files already carry their own context. Can be added later without breaking anything.

### Key insight: two different problems conflated

Agentic orchestration literature conflates two distinct use cases:

1. **Long-term agent operation** — a 24/7 chatbot, customer service agent, or autonomous system that runs indefinitely. Needs persistent memory, state machines, failure recovery, retry budgets, monitoring, self-healing. This is the Symphony/Praetorian world.

2. **Long-ish but finite coding sessions** — a multi-step implementation that takes 5-30 minutes and ends. Needs context management (amnesia) and basic chaining. Does *not* need retry logic, state machines, or self-healing. The session is over when the last chunk executes.

Most orchestration tooling is built for case 1 and then applied to case 2, resulting in over-engineering. 3code's `clear` with `next_file` targets case 2 specifically: a simple chain for finite sessions where the human verified the model works well manually.

### Filename vs string disambiguation (deferred)

`next_file` could also accept freeform strings for non-file use cases. Needs a way to distinguish filenames from strings without ambiguity. Shelved in `ideas.md` until a real use case surfaces.
