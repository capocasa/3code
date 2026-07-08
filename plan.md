# Plan: collapse persistent + wizard into a single input-thread state machine (item 10)

## Context for whoever picks this up

This is the **backlog item from `plan2.md` (item 10)** in
`~/p/3code/profreeze/`. Items 1, 8, 2, 9, 4, 3, 6, 7, 5 from
that plan are all DONE as of commit `00fbca6` (the
`profreeze` branch HEAD when this was written). Read
`~/p/3code/profreeze/plan2.md` and `~/p/3code/profreeze/plan.md`
before starting; the original `plan.md` documents the cancel fix
that motivated this refactor (the input thread now owns stdin
uniquely and the wizard runs through a `wizardReadLine` RPC
instead of a second `posix.read`).

The branch is `profreeze`. The current HEAD is
`54fd52c plan2: mark item 5 done (00fbca6); header rename +
status block` (or whatever is on top when you pick this up —
rebase as needed).

## Why this work exists

The current architecture is "the input thread runs a persistent
`readLineWith` loop; when a wizard request arrives, it yields
the loop and runs a wizard `readLineWith`." This works but
it's two state machines glued together via:

- A free-floating `inputModalActive: Atomic[bool]` flag that
  every hook body in `inputThreadProc` consults
  (`runtime.nim:102, 447, 1556, 1571, 1603`).
- A `try/finally` block in the wizard branch that swaps
  `edPtr[].deferSubmit` and `edPtr[].submitIcon` to the
  wizard's values and back
  (`runtime.nim:1753-1773`).
- A `wizardRequestPosted` / `wizardResponsePosted` handshake
  that crosses the main-thread / input-thread boundary
  (`runtime.nim:115-130, 1889`).
- A `wizardRequestLock: Lock` that protects the request /
  response structs (the flags are lock-free; the lock is for
  the structs only).
- A `WizardSwitched` exception type in `minline.nim` that the
  persistent `readLineWith` raises when the input thread's
  `getCh` returns the `wizardSentinel` (-2).

The `inputModalActive` flag is a one-bit version of the actual
state machine. Extending it for future modals (e.g. a "pause
streaming for a question" modal) without first collapsing the
architecture is what got us into the original cancel bug in
the first place. The state machine has at least four states
the current code doesn't name:

- `IdlePersistent` — the persistent prompt is up, the input
  thread is in `getCh` waiting for a byte.
- `WizardPrompt` — the persistent prompt yielded via
  `WizardSwitched`, the input thread is in the wizard's
  `readLineWith` running a modal prompt.
- `IdleTurn` — a turn is running, the persistent prompt is
  hidden, the input thread accepts buffered autosend text.
- `TurnPersistent` — same as `IdlePersistent` but the input
  thread's `onSubmit` pushes an `ieLine` event instead of
  an `ieCommand` (because the controller hasn't drained
  it yet).

(You may find more states once you start; these are the four
I can see without doing the work.)

## Goal

Replace the flag + lock + sentinel + exception protocol with a
single explicit state machine in the input thread. Transitions
are driven by the main thread posting a `WizardReadRequest`
(or, in the future, a `TurnInterruptionRequest`, or a
`PauseStreamingRequest`, etc.) to the input thread's event
queue. The input thread's outer loop becomes a
`while inputRunning(): case currentState of:` where
`currentState` is an atomic enum, not a free-floating flag.

After the refactor:

- `inputModalActive` is gone. Replaced by `inputState` (an
  enum), with `inputState.load(moAcquire)` returning the
  current state.
- `wizardRequestPosted` / `wizardResponsePosted` /
  `wizardRequestLock` are gone. Replaced by a typed
  `Channel[WizardEvent]` (Nim's `system.Channel`) where
  `WizardEvent` is a sum type of `WizardRequest` /
  `WizardResponse` / `TurnInterruption` / etc. Channels
  give us the blocking semantics the current
  atomic-flag + 5ms-poll idiom implements by hand.
- `WizardSwitched` is gone. The persistent `readLineWith`
  no longer needs to raise an exception to hand off to the
  wizard; it returns a `LineResult` enum (line / cancelled
  / interruptedByModeChange) and the input thread's outer
  loop pattern-matches on it.
- `wizardSentinel` (-2) is gone. `getCh` no longer needs to
  signal mode changes via a magic int.
- The hook closures (`onMutate`, `onSubmit`,
  `onCancelDeferredSubmit`, `preRedraw`, `postRedraw`)
  stop consulting `inputModalActive`. They consult
  `inputState` via a single atomic load, or they get
  set/unset when the state transitions (the hooks for
  state X are different from the hooks for state Y).

## What stays the same

- `LineEditor` is still shared between threads (it's a
  `var` in `threecode.nim` and a pointer in
  `inputEditor`).
- The `readLineWith` proc is the same — its signature
  doesn't change. Only the `getCh` and the hook bodies
  change.
- The termios raw mode setup is the same.
- The bracketed-paste enable at termios setup is the same.
- The wizard RPC's external contract (main thread calls
  `wizardReadLine`, gets a line back or
  `InputCancelled` / `EOFError`) is the same.
- The persistent prompt's visible behaviour is the same.
- The wizard prompt's visible behaviour is the same.

## Suggested order of operations

These are NOT steps; each is its own PR. The order is
ordered by "what unblocks what" so a refactor of any one
step lands cleanly without breaking the others.

### Step 1: extract `WizardReadRequest` / `WizardReadResponse` into a `Channel`

**Files:** `src/threecode/fatprompt/runtime.nim`

Today the wizard RPC is hand-rolled: a struct + a lock + two
atomics + a 5ms `sleep` poll. `system.Channel[T]` gives you
all of that for free, with backpressure and zero polling.
Change `wizardRequestPosted` / `wizardResponsePosted` /
`wizardRequestLock` to a single
`var wizardChannel: Channel[WizardMessage]` where
`WizardMessage` is `WizardRequest | WizardResponse`.

The poll loop in `wizardReadLine`
(`while not wizardResponsePosted.load(moAcquire): sleep 5`)
becomes a `recv` on the channel. The wizard branch in
`inputThreadProc` (`acquire wizardRequestLock; try: ...`)
becomes a `recv` followed by a `send`. The `try/except`
around the `acquire/release` becomes the channel's own
synchronisation.

**Acceptance:** all 4 cancel subtests + the 20-iter stress
test + the item-1 edit-crash test still pass. The
`WizardSwitched` mechanism stays in place; this is just
transport. Behaviour is identical.

### Step 2: introduce `InputState` enum and a `setInputState` proc

**Files:** `src/threecode/fatprompt/runtime.nim`

Add:

```nim
type
  InputStateKind* = enum
    istateIdlePersistent  # the persistent prompt is up
    istateWizardPrompt    # a modal is running
    istateIdleTurn        # a turn is running, prompt hidden
    istateTurnPersistent  # a turn is running, prompt up

var inputState: Atomic[InputStateKind]
inputState.store(istateIdlePersistent, moRelease)
```

Add `setInputState(new: InputStateKind)` that does
`inputState.store(new, moRelease)` and (importantly) calls
a new `installHooksFor(state)` proc that sets / unsets the
hook closures based on the state. The current
`inputModalActive` stays in place; the new `inputState`
runs alongside it. The hooks consult BOTH (the new state
takes precedence where it disagrees, but during the
transitional period they should agree).

The state transitions so far are:

- `istateIdlePersistent → istateWizardPrompt` — when
  `wizardRequestPosted` is set, the wizard branch sets
  `inputState` to `istateWizardPrompt` after the
  `inputModalActive.store(true)`.
- `istateWizardPrompt → istateIdlePersistent` — when the
  wizard's `readLineWith` returns, the wizard branch sets
  `inputState` back to `istateIdlePersistent` after the
  `inputModalActive.store(false)`.
- `istateIdlePersistent → istateIdleTurn` — when a turn
  starts (`beginTurn` in `runtime.nim:1917`).
- `istateIdleTurn → istateTurnPersistent` — when the
  controller's first `ieLine` event during the turn
  gets the prompt to show buffered text.
- `istateTurnPersistent → istateIdleTurn` — when the
  controller drains the buffered event and the prompt
  hides again.

**Acceptance:** every test still passes. `inputModalActive`
is still the source of truth; `inputState` is a parallel
read-only view. A `runtime.nim` comment says so
explicitly.

### Step 3: move hook installation into `installHooksFor(state)`

**Files:** `src/threecode/fatprompt/runtime.nim`

Right now, the input thread's hook bodies consult
`inputModalActive.load(moAcquire)` at the top of each
closure and return early if true. This works but it's a
state check inside every hook — which means every hook
has to know the state machine.

Move the hook bodies to "hooks for state X" sets. The
persistent prompt gets one set (with `preRedraw` /
`postRedraw` that paint the footer). The wizard gets a
different set (with `preRedraw` / `postRedraw` that are
no-ops). `installHooksFor(state)` swaps the closures on
`edPtr[]` based on the state.

**Acceptance:** all hooks now have NO state checks in their
bodies. They just do their work. State transitions swap the
closure set. The `inputModalActive` flag is still set in
parallel so the persistent prompt's `getCh` parking check
(line 1571) still works — but a comment says "this is now
redundant with `inputState == istateWizardPrompt`; remove in
step 4."

### Step 4: remove `inputModalActive`

**Files:** `src/threecode/fatprompt/runtime.nim`

Every site that consulted `inputModalActive` (the hooks,
the `getCh` parking check, the `wizardReadLine` reset
sequence) is now driven by `inputState`. The flag and
its `var` declaration go away. The `inputState` atomic
enum is the single source of truth.

**Acceptance:** `grep -n inputModalActive src/` returns no
production hits. (The protocol comment in
`runtime.nim:102-110` documents the old flag's contract;
that comment can stay as historical context or be
removed.) All tests pass.

### Step 5: remove `WizardSwitched` and `wizardSentinel`

**Files:** `src/threecode/minline.nim`,
`src/threecode/fatprompt/runtime.nim`

`WizardSwitched` was a hack to make the persistent
`readLineWith` return without raising a real exception.
The cleaner design: `readLineWith` returns
`LineResult` (an enum) and the caller pattern-matches.

```nim
type LineResult* = enum
  lrSubmitted  # Enter pressed
  lrCancelled  # ESC / Ctrl-C
  lrEof        # Ctrl-D on empty line
  lrModeChange # NEW: the input thread changed state under us
              # (e.g. a wizard request arrived). The caller should
              # discard the line and re-enter the editor for the
              # new state.

proc readLineWith*(...): tuple[result: LineResult, text: string]
```

`lrModeChange` replaces `WizardSwitched` with a return
value, not an exception. The input thread's persistent
`readLineWith` returns `(lrModeChange, "")` when the
`getCh` returns the sentinel (or, in the new design, when
`inputState` transitions to `istateWizardPrompt` between
two `getCh` calls).

The `getCh` no longer needs the sentinel. It just returns
the next byte, or -1 on EOF, or blocks. The input thread
checks `inputState` between `readLineWith` calls to
decide whether to run the persistent or the wizard.

**Acceptance:** all tests pass. The
`except minline.WizardSwitched:` branches in
`inputThreadProc` are gone. The
`if c1 == wizardSentinel:` check in `readLineWith` is
gone.

### Step 6 (optional, future): typed events for the state machine

**Files:** `src/threecode/fatprompt/runtime.nim`,
`src/threecode/types.nim`

Today the input thread's event queue is a
`seq[InputEvent]` (where `InputEvent` is
`ieNone | ieLine | ieCommand | ieInterrupt | ieQuit`).
The state machine needs MORE events:

- `ieModeChange` — a wizard, pause, or other modal started.
- `ieModeResume` — the modal returned, resume the previous
  state.

These are queued the same way `ieLine` is queued today.
The controller pattern-matches on the event kind.

**Acceptance:** this is a future-friendly addition. It
doesn't change current behaviour, just expands the event
space. Skip for now if the state machine alone is enough.

## Risks

- **Hook installation is a state machine, not a list.** If
  the wizard runs while a turn is also running (i.e.
  "pause streaming for a question" — the original
  motivation for this refactor), the hook set for
  "turn + wizard" is different from the hook set for
  "idle + wizard." Step 3 needs to handle the
  composition. A simple way: hooks are functions of
  `inputState` directly (not a precomputed set), so
  `installHooksFor(state)` computes the right hook set
  from `state` alone. A more complex way: hooks are
  layered, and `installHooksFor(state)` composes layers
  based on a state hierarchy. The simple way is fine for
  now; the complex way is a future refactor.

- **The persistent prompt's `getCh` parking check
  (`inputIdleLinePending` + `not inputModalActive`)
  becomes `inputState == istateIdlePersistent` in the new
  design.** That change is mechanical but the existing
  test for it (`test_empty_enter_freeze.nim`) is the
  right regression barrier.

- **`WizardReadResponse` → `WizardReadResult` channel
  message type** in step 1 is a renaming + an enum. Make
  sure the cancel test still works (the
  `wizardReadLine` raises `InputCancelled` on cancel,
  not on `wrCancelled` directly — the test cares about
  the user's experience, not the channel type).

- **Step 5 is the biggest semantic change.** The other
  steps are mechanical refactors; step 5 changes the
  control flow. Land steps 1-4 first, get the stress
  test passing, then do step 5.

## What to test

The regression barriers already in place:

- `tests/tty/test_provider_wizard_cancel.nim` (4
  subtests): single-cancel + double-cancel scenarios.
- `tests/tty/test_provider_wizard_cancel_stress.nim`:
  20-iter state-machine stress.
- `tests/tty/test_provider_edit_crash.nim`: the original
  segfault regression (item 1 of plan2).
- `tests/tty/test_empty_enter_freeze.nim`: the
  `inputIdleLinePending` parking contract.
- `tests/tty/test_interrupt_prestream_freeze.nim`: ESC /
  Ctrl-C during a turn.
- `tests/core/test_minline.nim`: 74 subtests including
  the 5 `minline editor: bracketed paste` tests.

If a step breaks one of these, the step is wrong.
Don't paper over the test failure; find the regression
in the refactor.

## Knowledge from shipping items 1, 8, 2, 9, 4, 3, 6, 7, 5

(From `plan2.md`'s "What I learned" section. Reproduced
here so the next person doesn't have to read both files.)

- The plan's description of items 2, 4, and 5 was wrong
  (the "duplicate" wasn't a duplicate; the trim wasn't an
  add; the "nested" enable wasn't nested). For item 10,
  double-check the "two state machines glued together"
  framing by reading the actual current code. The
  framing may be right or may be a misread; the test is
  whether the refactor touches the four states I named
  (IdlePersistent, WizardPrompt, IdleTurn,
  TurnPersistent) or surfaces more.

- Item 8 turned out cleaner than the plan predicted
  because the `try/finally` unification of the publish
  path was a real improvement, not just a refactor.
  Item 10 may have a similar moment where the new
  design is SIMPLER than the old, not just more correct.

- Item 6 (the stress test) should be the FIRST thing
  added when starting this refactor. If a state-machine
  bug shows up, the stress test catches it; the
  single-cancel subtests don't. The current 20-iter
  test is the regression barrier.

- Item 5's "medium risk" label was overstated because
  the framing was wrong. If item 10's risk also feels
  high, re-read the framing before estimating. The risk
  may be in the framing, not the work.

## Suggested first step for whoever picks this up

1. Read `~/p/3code/profreeze/plan.md` (the cancel fix
   that motivated this refactor) and `~/p/3code/profreeze/plan2.md`
   (the 9 items that preceded this handoff).
2. Read `src/threecode/fatprompt/runtime.nim:1-200` (the
   globals, the protocol comment, `wizardReadLine`).
3. Read `src/threecode/fatprompt/runtime.nim:1680-1740`
   (the wizard branch in `inputThreadProc`).
4. Run the stress test: `nim c -r --path:src --path:tests
   tests/tty/test_provider_wizard_cancel_stress.nim`. See
   it pass. This is your baseline.
5. Land step 1 (the `Channel` refactor) as one commit.
   The protocol comment in `runtime.nim:113-169` is the
   spec; the new code should match it with the channel
   call replacing the polling loop.
6. Then steps 2-5 in order. Each is its own commit. Tests
   between each. Don't bundle.