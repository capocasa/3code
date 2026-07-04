# Plan: kill tty functional test flakiness

## The symptom

`tests/tty/test_tty_functional.nim` fails non-deterministically. Different
subtests fail on different runs; none is individually broken. Observed flaky
subtests across this session (3 isolated runs + parallel runs):

- `bash tool success and nonzero exit`
- `harness commands are transcript items`
- `non-bash tool transcript shapes`
- `ctrl-c during active api streaming then prompt accepts input`
- `multiline prompt and queued multiline autosend`

The suite passes reliably when the `tty` category runs **alone** (no other
test compilation competing for cores). It flakes when run in parallel under
load, and occasionally even in isolation. Exit code flips: a `check` failure
makes the binary exit non-zero.

## Root cause analysis (from reading the code this session)

The harness (`tests/tty_expect.nim`) and the stub provider
(`testdata/stub/provider.nim`) already have the machinery for **deterministic
synchronization**, but the `expect*` procs don't use it. They poll on
**wall-clock deadlines** instead.

### Finding 1: expect* polls on wall-clock, not on events

Every assertion proc is a busy-loop:

```nim
proc expectInHistory*(s: TtySession; text: string; timeoutMs = 5000): bool =
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    s.drain(5, recordFrame = false)   # poll up to 5ms
    if text in s.historyText(): return true
    sleep 5                            # then sleep 5ms
  doAssert false, "expected text not found: " & text
```

(`expect`, `expectTypedAtPrompt`, `expectTokenBar`, `expectCount` are all
shaped identically.) Under load, the OS may not schedule this loop promptly.
The 5s timeout is generous for a single assertion, but a test makes dozens of
sequential `expectInHistory` calls back-to-back; a few slow drains compound,
and a later assertion can time out before the child has produced the bytes.

This is the load-sensitivity mechanism: it's not the child misbehaving, it's
the harness's polling cadence being starved.

### Finding 2: the deterministic sync channel already exists but is unused by expect*

`testdata/stub/provider.nim` calls `emitTestFrameEvent()` at every
meaningful render boundary: after each reasoning chunk, each content chunk,
after live content finishes, after final usage, and after the spinner stops.
`emitTestFrameEvent` writes one byte to the `THREECODE_TEST_FRAME_FD` pipe and
**blocks reading an ack** from `THREECODE_TEST_FRAME_ACK_FD`.

`tty_expect.nim`'s `pollOnce` already watches that pipe (`pfds[1] =
s.frameEventFd`) and acks it. So the child already tells the harness "I just
rendered something new, here is a frame, now you may proceed." But `expect*`
ignores this signal and polls blindly.

This is the key insight: **the child and harness could synchronize on frame
events instead of on sleep timers.** An `expect` that blocks on
`poll(frameEventFd)` until the child emits a frame, *then* checks the screen,
removes the wall-clock race entirely. The child won't advance past the frame
boundary until acked, so the harness can never miss the state it's asserting
on.

### Finding 3: `send` has an implicit wall-clock wait

`send` writes bytes then polls up to 1s waiting for the printable echo to
appear in the grid. For control sequences (ESC, Ctrl-C) it polls 1s blind.
Under load this can also starve, and a too-fast follow-up `send` can outrun
the child's input processing. Less of a contributor than Finding 1 (the 1s
budget is large) but the same class of bug.

### Finding 4: tests run the real stub streaming clock

Stub responses carry `preStreamDelayMs`, `contentChunks`, `reasoningChunks`.
The provider sleeps for `preStreamDelayMs` (in 100ms slices, interruptible)
and streams chunks. The chunk inter-arrival is near-instant (no inter-chunk
delay in the stub), but the *rendering* of each chunk goes through the real
async pipeline + terminal renderer. So `expectInHistory "ok-two"` after
sending the prompt is racing the full render path, not a fixed delay. This is
fine in principle but only reliable if the harness synchronizes on render
completion (Finding 2) rather than guessing when it's done.

## The plan, in dependency order

### Step 1 — `expect*` waits on frame events, falls back to wall-clock (the core fix)

Change the assertion procs to synchronize on the frame-event channel before
checking screen state, with the wall-clock timeout kept purely as a safety net
(detecting a dead child, not pacing a live one):

  1. `pollOnce` on both the PTY fd and `frameEventFd`.
  2. When a frame event arrives: ack it, drain the PTY, **then** check the
     predicate. The child is blocked on the ack, so the screen state is frozen
     and stable at this instant.
  3. Only if no frame event arrives within a short window (say 200ms) AND the
     predicate is still unsatisfied do we fall through to a wall-clock poll.
     This covers the rare case where the text was already on screen before we
     started waiting (no new frame needed).
  4. The existing `timeoutMs` stays as the hard cap for detecting a hung child
     or a genuine missing feature.

This single change addresses Finding 1 and Finding 2 together. The child
becomes the clock: the harness asserts against a frame the child explicitly
handed it, not against whatever happens to be on screen when a 5ms timer fires.

Risk: the stub must call `emitTestFrameEvent()` at every state an `expect`
could assert on. Audit the call sites in `provider.nim` (there are ~6) against
the render boundaries the tests assert on. Gaps → add a frame emit. Most are
already covered (content chunk, reasoning chunk, content finish, usage,
spinner stop).

### Step 2 — make `send` synchronize too

After writing input bytes, `send` should wait for the echo via the frame-event
channel (the child repaints on input, which triggers a frame emit) rather than
a 1s blind poll. Same pattern as Step 1. Addresses Finding 3.

For control-sequence sends (ESC, Ctrl-C) where there is no printable echo,
have the stub emit a frame event after it processes the interrupt / mode
change (it already emits after `hookStopSpinner` on interrupt — extend to
cover the interrupt-acknowledgment path).

### Step 3 — audit the flaky tests against the new sync model

After Steps 1-2, run each previously-flaky subtest in a tight loop
(`THREECODE_TTY_ONLY=<name>` isolates a single subtest) under parallel load to
confirm the race is gone. If a specific subtest still flakes, it indicates a
missing `emitTestFrameEvent` at the boundary it asserts on — add the emit,
don't loosen the assertion. The existing `THREECODE_TTY_ONLY` env hook and the
per-run `dumpFramesAround` diagnostic make this loop productive.

### Step 4 — drive the spinners deterministically (already partly done)

The harness already has `advanceTicker` / the ticker-command pipe
(`THREECODE_TEST_TICKER_FD`) to step the spinner on demand instead of letting
it run on a real timer. The frame normalization (`normalizeSpinnerPhases`)
papers over residual spinner frames in visual comparisons. Confirm the flaky
*non-visual* assertions (which don't compare frames) aren't asserting on
spinner text that depends on timer phase — if any do, route them through
`advanceTicker` so the phase is deterministic.

## What NOT to do

- **Do not increase timeouts.** That masks the race and makes the suite slow;
  it doesn't remove the non-determinism.
- **Do not add retries to flaky `expect*` calls.** Retry-on-failure is the
  pattern that hides real regressions. The frame-event sync removes the race
  without retry.
- **Do not disable the flaky subtests.** They guard real concurrency bugs
  (that's why they exist). The flakiness is a harness timing defect, not a
  defect in what they test.

## Verification

- Each flaky subtest run 20x in isolation + 20x under full parallel load: 0
  failures.
- Full `testament --megatest:off all` run 5x: 0 failures, no exit-code flips.
- The suite should get *faster*, not slower: frame-event-driven `expect` returns
  as soon as the child signals the frame, instead of sleeping 5ms between
  polls.

## Scope guard

This is a harness-only change: `tests/tty_expect.nim` + possibly a few
`emitTestFrameEvent` additions in `testdata/stub/provider.nim`. No changes to
`src/` production code, no changes to test bodies, no changes to the visual
fixture comparison logic.
