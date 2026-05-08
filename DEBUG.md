# Debug: UI freeze during tool calls

## Resolution

**Fixed.** The root cause was a combination of the pending banner consuming the
bar's screen row without guaranteeing a repaint, and the spinner/thread timing
being fragile across the tool-execution boundary.

The fix replaced the pending-banner pattern with a bar-tick mechanism:
during tool execution, a lightweight thread repaints the token bar every 500ms
with an incrementing elapsed counter (no spinner icon). The result banner is
written after the tool completes, inside a single `withCleared`.

## What changed

- **Removed** `renderToolPending` call from `runTurns`. No more pending banner
  during tool execution.
- **Added** `startBarTick`/`stopBarTick` in `api.nim`: a thread that repaints
  `barFooterBytes` with `baseLabel + " " + elapsedS + "s"` every 500ms.
- **Simplified** result output: no cursor walk-up (`\e[1A\r\e[2K`), just a
  `withCleared` that writes the final banner and output.

## Remaining suspected causes (from original analysis)

The missing-usage and spinner-race hypotheses are less likely now that the
pending-banner path is eliminated. If further display issues appear, the
bar-tick mechanism is a cleaner foundation to debug from.

## Stub provider (kept for future debugging)

A compile-time stub bypasses all network and KnownGoodCombo logic.
`callModel` returns canned responses from `stub_responses.json` in the
cwd. Each call pops the next response from the array.

### Building

```sh
nim c -d:providerStub --out:build/3code-stub src/threecode.nim
```

### Testing on a real TTY

```sh
build/3code-stub --debug 2>stub_debug.log
```
