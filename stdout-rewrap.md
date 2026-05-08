# Issue: Dialog text does not re-wrap on terminal resize

## Problem

When the terminal is resized during prompt input, the dialog text above the prompt (assistant responses, tool output) retains the line breaks from the old terminal width. Only the prompt editing area (minline) re-renders via `fullRedraw`.

## Root cause

All dialog output is written directly to stdout with explicit `\n` line breaks computed by `wrapAnsi()` at the current terminal width. There is no mechanism to walk back and repaint this output at a new width.

Key call chain:

1. `api.nim:streamAndDispatch()` streams the assistant response. Each chunk is fed through `handleMdLine()` → `wrapAnsi()` → `stdout.write` with explicit newlines.
2. Tool results are rendered via `display.nim:printBashCompact()`, `printDiff()`, `printToolResult()` etc., all using `wrapAnsi()` with `bodyW = terminalWidth() - indent`.
3. On SIGWINCH, `minline.nim` sets `resizePending = true`, which triggers `fullRedraw(ed)` during the next keystroke — but this only repaints the prompt editing area.

## Where the wrapping happens

- `util.nim:245` — `wrapAnsi(s, width)` — greedy word-wrap splitting text into fixed-width chunks.
- `display.nim:111,149,188,195,200,246,256,646` — all dialog rendering calls `wrapAnsi` with a width derived from `terminalWidth()`.
- `api.nim:860` — streaming path: `handleMdLine(mdState, l, stdout)` — renders each markdown line to stdout with wrapping baked in.

## State available at repaint time

During prompt input (`ui.nim:readInput` → `minline.nim:readLine`), the following is available:

- `messages: JsonNode` — full conversation history including assistant content and tool calls
- `session.toolLog: seq[ToolRecord]` — tool call log with arguments and results
- `api.nim:currentBarLabel` — the status bar label
- `minline.nim:ed.renderRow` / `ed.echoRows` — prompt area geometry
- `minline.nim:resizePending` — set by SIGWINCH handler

## Proposed approach

Track the visual row count of the current turn's dialog output, and on resize, walk back and repaint from the raw content already stored in `messages` and `toolLog`.

### 1. Track dialog row count

Add a module-level var (e.g. in `api.nim` or a new shared state module):

```nim
var turnDialogRows*: int = 0   # visual rows written since last prompt
```

Every `syncWrite` / `stdout.write` that emits dialog text increments this (counting `\n` chars). Alternatively, wrap the output in a counting layer.

### 2. On resize, repaint dialog + prompt

Extend the SIGWINCH handling in `minline.nim:readLine` (line ~1022):

```nim
if resizePending:
  resizePending = false
  # Walk up past dialog rows, clear, repaint dialog, then fullRedraw prompt
  if turnDialogRows > 0:
    stdout.write "\x1b[" & $turnDialogRows & "A"  # move to top of dialog
    stdout.write "\r\x1b[J"                        # clear from there down
    replayDialog(messages, toolLog, stdout)         # repaint at new width
    turnDialogRows = countDialogRows(messages, toolLog)
  fullRedraw(ed)
```

### 3. `replayDialog` procedure

A new proc (likely in `display.nim`) that re-renders the current turn's content from the raw message/toolLog data:

- Re-render assistant content via `renderAssistantContent` (already handles markdown + wrapping)
- Re-render tool results via the existing `printToolResult` / `printBashCompact` / `printDiff` procs
- These all call `wrapAnsi` with the current `terminalWidth()`, so they naturally use the new width

### 4. Reset row counter

- At the start of each turn (before streaming begins), reset `turnDialogRows = 0`
- Each write during the turn increments it
- After repaint on resize, update it to the new count

## Complications

- **Streaming output with live bar**: During streaming, the output has a live status bar that moves around. The resize only matters during prompt input (between turns), so this isn't a problem — the dialog is already complete.
- **Multiple turns visible**: The user may have scrolled back. We can only repaint what's currently above the prompt and below the scroll region. For a first cut, only repaint the last turn's output.
- **ANSI escape codes**: The bar footer uses CSI s/u (save/restore cursor). Walking back through dialog rows needs to account for these.
- **Scrollback**: If the turn output is longer than the terminal height, the top portion has scrolled off and can't be repainted. Only the visible portion can be re-rendered. This is an inherent limitation of the primary screen buffer.

## Simpler alternative: count-and-replay-last-turn

Instead of tracking every write, just count the visual rows at the end of each turn (from messages/toolLog), store that count, and use it to walk back on resize. The raw content is always available in `messages`.

## Files involved

- `src/threecode/minline.nim` — SIGWINCH handler and resize path (~line 1022)
- `src/threecode/api.nim` — streaming output, bar state, syncWrite
- `src/threecode/display.nim` — all dialog rendering procs
- `src/threecode/util.nim` — wrapAnsi, terminalWidth
- `src/threecode/types.nim` — shared types (ToolRecord, etc.)
- `src/threecode/ui.nim` — readInput, the entry point before minline
