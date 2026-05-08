# Implementation Plan: `clear` Tool

## Overview

Rename `context_clear` → `clear`. Single string parameter that accepts either a filename or freeform instructions. Filenames are auto-detected by pattern (ends with `.<ext>` up to 4 chars, under 128 chars). If it looks like a filename but doesn't exist, return "file not found" as tool result — model gets 3 retries to correct. If it doesn't look like a filename, treat as instructions and clear immediately.

## Files to change

1. `src/threecode/types.nim` — Action type
2. `src/threecode/actions.nim` — parse and format
3. `src/threecode/prompts.nim` — tool definitions and prompt text
4. `src/threecode.nim` — handler in main loop
5. `src/threecode/skills/task-chunked-implementation.md` — skill instructions

(`display.nim` keeps `⟳` symbol — no change needed.)

## Step-by-step

### 1. `src/threecode/types.nim`

Add a `clearRetries` counter to the session loop state (or similar location where turn-scoped state lives). This tracks consecutive failed filename attempts in the current session.

The Action type currently has:
```nim
summary*: string
instructions*: string
```

Replace with a single field:
```nim
content*: string  ## clear: filename to load, or freeform instructions
```

Keep `summary` and `instructions` fields but make them secondary — the handler uses `content` as the primary input. Alternatively, just use the existing `instructions` field for the unified content and deprecate `summary`. Simpler: rename `instructions` → `content`, drop `summary`. But backward compat matters — the model might still pass `summary` + `instructions`. Accept all three, prefer `content` if present, else fall back to `summary + "\n\n" + instructions`.

### 2. Helper: `looksLikeFilename(s: string): bool`

Add a small helper proc (in actions.nim or a utils module):

```nim
proc looksLikeFilename(s: string): bool =
  ## Heuristic: ends with .<ext> (1-4 chars after dot), length <= 128,
  ## no newlines, and doesn't look like a sentence.
  if s.len > 128 or '\n' in s: return false
  let lastDot = s.rfind('.')
  if lastDot < 0: return false
  let ext = s[lastDot+1 ..^ 1]
  if ext.len < 1 or ext.len > 4: return false
  # Extension should be alphanumeric only
  for c in ext:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9'}: return false
  return true
```

### 3. `src/threecode/actions.nim`

**Parse action** (~line 85-90): Update `contextClearAction` to read a unified `content` field, with fallback to old `summary`+`instructions`:

```nim
proc contextClearAction(args: JsonNode): Action =
  result = Action(kind: akContextClear)
  if args.hasKey("content"): result.content = args["content"].getStr
  elif args.hasKey("instructions"):
    result.content = args["instructions"].getStr
    if args.hasKey("summary"):
      result.content = args["summary"].getStr & "\n\n" & result.content
```

Note: keep `summary` and `instructions` populated for display/logging, but `content` is what the handler uses.

**Format action** (~line 155-170): Update the `akContextClear` branch to show the new unified parameter.

**Banner text** (~line 611): Update display text for `akContextClear`.

### 4. `src/threecode/prompts.nim`

**Tool definition** (~line 690): Rename `contextClearTool` → `clearTool`. Replace the two-parameter schema with a single parameter:

```json
{
  "name": "clear",
  "description": "Clear conversation history and start fresh. Pass a filename (e.g. impl-2.md) to load that file as the next context — use this for chaining chunks. Pass a string for freeform instructions. If a filename doesn't exist, you'll be told — correct and retry.",
  "parameters": {
    "type": "object",
    "properties": {
      "content": {
        "type": "string",
        "description": "A filename to load (e.g. impl-2.md) or freeform instructions for the fresh context."
      }
    },
    "required": ["content"]
  }
}
```

Keep the old `summary`/`instructions` parameters as optional for backward compat — old prompts that pass them still work.

**Prompt text** — find-and-replace all `context_clear(summary, instructions)` references with `clear(content)`. Update descriptions. Locations: ~lines 109, 175, 176, 478, 630.

### 5. `src/threecode.nim` (~line 166-185)

Replace the current handler with:

```nim
if act.kind == akContextClear:
  let sys = if messages.len > 0 and
               messages[0]{"role"}.getStr == "system": messages[0]
            else: %*{"role": "system", "content": ""}

  let c = act.content

  if looksLikeFilename(c):
    if not fileExists(c):
      # Retry logic: tell model, don't clear
      session.loop.clearRetries.inc
      if session.loop.clearRetries > 3:
        toolContent &= "\n\n[clear error] file not found after 3 attempts: " &
          c & ". Stopping — check filenames and retry manually."
        halt = true
      else:
        toolContent &= "\n\n[clear] file not found: " & c &
          ". Check the filename and call clear again with the correct path."
      # Do NOT clear context — model stays in current session to retry
    else:
      # Valid file — clear and load
      session.loop.clearRetries = 0
      let freshMsg = readFile(c)
      let rebuilt = newJArray()
      rebuilt.add sys
      rebuilt.add %*{"role": "user", "content": freshMsg}
      messages.elems.setLen 0
      for m in rebuilt: messages.add m
      withCleared:
        stdout.styledWriteLine styleDim,
          "  · clear — loaded " & c, resetStyle
      saveSession(session, messages)
      return
  else:
    # Freeform instructions — clear immediately
    session.loop.clearRetries = 0
    let rebuilt = newJArray()
    rebuilt.add sys
    rebuilt.add %*{"role": "user", "content": c}
    messages.elems.setLen 0
    for m in rebuilt: messages.add m
    withCleared:
      stdout.styledWriteLine styleDim,
        "  · clear — fresh session", resetStyle
    saveSession(session, messages)
    return
```

Add `clearRetries: int` to the session loop state (wherever `turnCalls` and similar counters live). Reset to 0 on successful clear.

### 6. `src/threecode/skills/task-chunked-implementation.md`

Update all references from `context_clear` to `clear`. Update the chunk file template:

```markdown
## Next step
When complete and verified, call clear with:
clear("impl-<N+1>.md")

(Last chunk omits this section entirely.)
```

Remove the old summary/instructions handoff pattern.

## Verification

1. Build: `nimble build`
2. Test chaining: create `test-1.md` and `test-2.md`. Ask model to work on test-1 content then call `clear("test-2.md")`. Should clear and load test-2.
3. Test retry: ask model to call `clear("nonexistent.md")`. Should get "file not found" and stay in session. Ask again with correct filename → should work.
4. Test retry limit: ask model to call `clear("fake-1.md")`, then `clear("fake-2.md")`, then `clear("fake-3.md")`, then `clear("fake-4.md")`. Should error and stop on the 4th attempt.
5. Test freeform: ask model to call `clear("Start fresh and implement a hello world")`. Should clear immediately with that string as instructions.
6. Test backward compat: ask model to call old-style `clear(summary: "test", instructions: "do something")`. Should work as before.
7. Run existing tests: `nimble test`
