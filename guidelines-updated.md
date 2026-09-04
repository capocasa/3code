# 3code Coding Guidelines (Updated)

Derived from a full code review (2026). These restate `.agents/design.md` and
`.agents/development-guide.md` where the code has drifted, and add rules the
review found missing. The two `.agents/` documents remain the source of truth;
this file is the enforcement layer for what we actually found in the tree.

## 1. One owner per concern, finished migrations only

The recurring failure mode of this project is "the new good way exists, but a
third of the code still does it the old way." Every architectural migration is
all-or-nothing:

- **Terminal layout has exactly one owner: `engine.nim`.** `terminal.nim` is
  its byte-serialization helper. No other module moves the cursor, erases
  rows, or paints footers.
- **History appends have exactly one path.** `transcript.nim` builds items,
  `engine.appendTranscript` commits them. Nothing else appends scrollback.
- **No legacy emitter stays behind.** A new render path lands only with the
  deletion of the path it replaces in the same commit series. A half-finished
  migration is worse than none: it doubles the code paths a bug can live in.

Current violations on the books (see cybernetic-plan.md):

- `fatprompt/runtime.nim` still carries the pre-engine paint helpers
  `paintBarPrompt`, `paintBarBelow`, `clearBarPrompt`, `repaintBarPrompt`,
  `paintPromptOnly`, `paintInitialBar`, `paintInitialPrompt`,
  `enterPromptInput`, `resetPromptInputAfterEmpty`. They bypass the engine's
  walk-up model and are the residue of the frame-model migration. They must
  be deleted, with callers moved to `FooterFrame` + `renderFooter`.
- `turns.nim` and `threecode.nim` contain a copy of
  `trimTranscriptTail` that already lives in `transcript.nim`.
- `ui.nim` and `display.nim` write scrollback directly (`hintLn`, `errLn`,
  `cmdResponse`, `cmdError`, styled status lines). View modules must return
  item bodies; the controller commits them.

## 2. The scrollback contract is append-only, no exceptions

From design.md: scrollback is append-only. Valid render operations never
touch committed rows. In practice this means:

- **No `stdout.write` of escape sequences outside `terminal.nim`,
  `engine.nim`, `minline.nim`.** A grep for `\x1b[` in controller code is a
  bug list. (The only current controller offenders write `\n` padding; those
  are spacing bugs in waiting, since spacing is owned by the append helper.)
- **Wizard output is scrollback.** The provider wizard prints status lines
  (`verifying... ok`, `added <name>`, model lists) straight to stdout while
  the fat prompt is parked via `inputModalActive`. That works today only
  because the modal flag freezes the renderer. It is one flag-handling bug
  away from overwriting the prompt. Wizard steps must emit their status as
  transcript items through the controller path after the modal returns, or
  paint through the engine like everyone else. The wizard may not keep its
  own private terminal posture.
- **Harness messages occupy exactly one ordinary line, appended once, through
  the same path as everything else.** `onTurnInterrupted` is the model:
  one line, one procedure, no special repaints.

## 3. Controller / transport / view separation

- `api.nim` is transport and protocol only. It currently complies (no view
  imports; retry notices go through the `retryNotice` hook). Keep it that
  way: nothing in `api.nim` may import display/fatprompt/terminal/minline or
  write a byte to the terminal. The `stderr.writeLine` debug dumps at
  api.nim:1677-1684 are a gray zone, acceptable as debug-only BUG reports,
  but they must never carry user-facing output.
- View modules return bytes or items; they never decide when something
  becomes history.
- `captureStdoutWrites` exists to adapt body-formatters that still write to
  stdout. It is an adapter, not a license: new formatters return strings,
  and each remaining `captureStdoutWrites` call site is a TODO to convert
  the formatter it wraps. When that count reaches zero the template is
  deleted, including its fd-duplicating Windows implementation.

## 4. Tests assert effects, not measures

- **Visual behavior is asserted on ttty grid frames.** The effect is "what
  the user sees on screen," not "which bytes were emitted." Byte assertions
  are only allowed for pure emitters whose API is bytes (token bar label
  formatting, ANSI helpers, width functions).
- **Known violations to fix:**
  - `test_tty_functional.nim:813-815` checks raw bytes for magenta/bright
    white; assert fg color on the grid cell instead.
  - The sync-payload scan at ~:1729-1790 parses `\x1b[J` inside
    synchronized frames; the equivalent grid-level invariant (frame diff:
    viewport rows blanked then redrawn) is what must be asserted.
  - `test_ticker_cleanup.nim` locates cleanup by searching raw for
    `\x1b[J`; assert the final grid state has no ticker remnant.
- **PTY tests drive the real binary and send real keystrokes.** Internal
  state inspection, helper-level shortcuts, and session-log assertions are
  supporting evidence only, never the primary reproducer for a screen bug.
- **Fixtures are edited deliberately, never regenerated.** A fixture is a
  spec. If a frame changed in a way the change description did not ask for,
  the code is wrong, not the fixture.
- **A stub that makes the bug impossible is not coverage** (hall-of-fame
  rule). The in-process stub answers in <100ms; real providers block in TLS
  recv for seconds. Any interrupt/cancel/timeout test must exercise the
  blocking path, via `mock_server.nim` with induced latency or equivalent,
  or it documents intent but tests nothing.

## 5. Control flow: handle one case, then return

Long nested `if` pyramids are the top readability problem in this tree
(measured: 15-20 indentation levels in `threecode.nim`, `engine.nim`,
`api.nim`, `minline.nim`, `ui.nim`, `session.nim`, `turns.nim`). The house
style is early-exit:

```nim
proc doThing(x: T): R =
  if x == nil: return
  if not x.valid: raise newException(ValueError, "invalid thing")
  let y = normalize(x)
  if y.len == 0: return defaultR
  # happy path at top indentation
```

- Validate preconditions first, return or raise immediately.
- Error cases are one line each, handled and left behind; the happy path
  stays flush left.
- `while true` + `continue` re-prompt loops (the wizard has 7) get the same
  treatment: validate, `continue` on the specific bad case, fall through to
  the single success exit.
- `func` when there are no side effects, `proc` normally, `template` when
  you must, `macro` never without asking. (Current tree: 585 procs, 8
  funcs. Formatting and parsing code is the conversion backlog.)

## 6. Concurrency: two locks, three flags, no more

The input thread / wizard handshake in `fatprompt/runtime.nim` is the most
delicate code in the project and the source of multiple SIGSEGV and
deadlock hall-of-fame entries. Rules that fall out of it:

- **All terminal writes hold the terminal write lock.** Background render
  threads are joined only via `withTerminalLockDroppedForJoin`.
- **Cross-thread state is `Atomic[bool]` + sleep-poll, matching the
  existing idiom.** No ad-hoc condvars, no new channels, no fourth
  synchronization pattern.
- **Every hook closure body must check `inputModalActive` before touching
  editor state** (torn-closure SIGSEGV rule, documented in runtime.nim).
- New cross-thread handshakes are not invented; existing ones
  (`wizardRequest`, idle-submit release, autosend queue) are reused.

## 7. Networking: streamhttp is the single transport

- streamhttp (0.4.5) is in good shape architecturally: pure chunked/identity
  body decoder, `SSL_pending`-aware TLS read path (the stdlib
  `net.recv(timeout)` loop is wrong for TLS and this is why we ship our own
  client), `SO_RCVTIMEO`/`SO_SNDTIMEO` kernel deadlines, bounded TLS
  handshake, non-blocking `close` that skips `close_notify`. The fixes for
  the bad-network bug class all live here and are correct in kind.
- Remaining sharp edges, in order of risk:
  1. **Blocking first DNS resolve per host.** Documented floor; the quiet
     watch cannot interrupt it. The fix is a bounded resolver thread, not
     more retries around `getAddrInfo`.
  2. **Process-lifetime DNS cache** with no TTL. Fine for a CLI session;
     keep `invalidateResolved` on every connect failure (already done).
  3. `sslSendAll`'s 50 x 100ms idle cap is a heuristic; `SO_SNDTIMEO` makes
     it mostly redundant. Keep both, but a send stall must surface as one
     typed error the retry layer recognizes, not a generic IOError.
  4. `close()` frees the SSL handle and closes the fd from any thread, but
     a concurrent `recv` on the same conn is then use-after-free territory.
     The current callers coordinate via `shutdown` + flags before close;
     that ordering is load-bearing and must be documented at every call
     site, not just inside streamhttp.
- No second HTTP client may appear on any streaming path; streaming is
  streamhttp, full stop. The four `httpclient` users (`api.nim`
  fetchModels, `compact.nim`, `web.nim`, `update.nim`) are BLESSED
  one-shot callers: bounded whole-body requests with explicit timeouts
  that need redirects and nothing else. Do not add new httpclient uses
  beyond those four.

## 8. Dependency handling

Local dependencies (ttty, streamhttp, sandwall, tinotify, ...) are checked
out under `~/p/<name>` and linked with `nimble develop -g` run once from
that repo. `nimble setup` in a consumer then resolves them to the source
dir; edits are live immediately, no reinstall step.

Agents must NOT `nimble install` new packages. Installing copies a frozen
snapshot into `~/.nimble/pkgs2`, which then shadows the develop link in
the SAT solve and silently poisons every later build with stale modules
(three separate ttty 0.5.1 copies with different content is the incident
on record). `nimble build` at most; prefer plain `nim c` with the
`nimble.paths` from `nimble setup`.

If a dependency resolves to `~/.nimble/pkgs2` instead of `~/p/<name>`:
delete the pkgs2 copy, and check `~/.nimble/pkgcache/tagged_versions.json`
for a stale entry for that package (the solver prefers tagged releases
over develop links, and a cache from before a tag was pushed hides it).

## 9. Misc hard rules

- No em dashes anywhere, including code comments.
- No Nim macros unless explicitly instructed.
- Commit at each coherent step; one line, unceremonial.
- Comments explain why, with the mechanism and the failure it prevents.
  The existing long header comments in runtime.nim/streamhttp.nim (bug
  archaeology) are the house style for concurrency and protocol code, and
  they have repeatedly paid for themselves. Keep them current; a stale
  protocol comment is worse than none.
- Dead code is deleted, not kept "for re-enabling" (`bufprompt.nim`'s
  unwired buffer API is the current example; either wire it or drop it).
- Session/cwd robustness (deleted cwd, broken stdout) is handled at the
  boundary, once, the way `runTurnWithSafetyNet` does; do not sprinkle
  per-call-site OSError catches.
