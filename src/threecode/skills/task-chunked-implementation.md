---
name: task-chunked-implementation
description: Break a large implementation task into sequential chunk-plan files, then execute each chunk in a fresh context using the context_clear tool. Use when a task is too big for one context window or when the model needs to work in stages with clean state.
---

# Chunked Implementation

## When to use

Use this skill when the user asks to implement a substantial feature, refactor, or multi-file change. The task should be broken into pieces that each fit comfortably in a single context window.

## Workflow

1. **Analyze the task.** Read the codebase as needed to understand scope, dependencies, and existing patterns. Produce a detailed mental model of what needs to change and in what order.

2. **Create the master plan.** Write a file called `impl-plan.md` in the project root (or cwd). This file contains:
   - A brief overview of the task.
   - An ordered list of chunks (3–7 is typical). Each chunk entry names the chunk and summarizes what it covers in 1–3 sentences.
   - The final chunk (if needed) is an "integrate and polish" pass.

3. **Create chunk plan files.** For each chunk in the master plan, create a separate file `impl-N.md` (where N is the chunk number, 1-based). Each chunk file contains:
   - **Goal**: what this chunk accomplishes.
   - **Files to read first**: list of files the agent should read before starting work.
   - **Detailed instructions**: step-by-step changes to make, including exact function names, type definitions, and expected behavior. Be specific enough that an agent with no prior context can execute correctly.
   - **Verification**: how to verify this chunk is complete (build command, test command, manual check).
   - **Next step**: the instruction to call `context_clear` with a summary of what was done and a reference to the next chunk file. Example:
     ```
     When this chunk is complete and verified, call context_clear with:
     - summary: "Implemented X, Y, Z. Build passes. Tests green."
     - instructions: "Read impl-2.md and execute the instructions there."
     ```

4. **Execute chunk 1.** Read `impl-1.md` and carry out its instructions. When done, use `context_clear` to summarize state and hand off to chunk 2.

5. **Each subsequent chunk.** The agent starts with fresh context and the instructions from the previous chunk's `context_clear` call. It reads the referenced chunk file and executes. When done, it calls `context_clear` again to hand off.

6. **Final chunk (optional).** The last chunk may be "integrate and polish" — run full builds, clean up, run all tests, remove the impl-N.md plan files if desired.

## Chunk file template

```markdown
# Chunk N: <title>

## Goal
<what this chunk accomplishes>

## Read first
- <file paths the agent should read before starting>

## Instructions
<step-by-step, specific enough for a fresh-context agent>

## Verification
<how to confirm correctness>

## Next step
When complete and verified, call context_clear with:
- summary: "<concise state summary>"
- instructions: "Read impl-<N+1>.md and execute the instructions there."
```

## Rules

- Each chunk must be self-contained: a fresh-context agent should be able to execute it using only the chunk file and the files it lists under "Read first".
- Prefer fewer, larger chunks over many tiny ones. Each context clear has overhead.
- Always verify (build, test) before calling context_clear.
- The summary passed to context_clear should mention: files changed, tests status, any open questions or partial work.
- The instructions passed to context_clear should start with reading the next chunk file.
- Keep the master plan (`impl-plan.md`) updated as chunks complete if discoveries change the plan.
- Do not call context_clear until the current chunk is verified. If something fails, fix it in the current context.
