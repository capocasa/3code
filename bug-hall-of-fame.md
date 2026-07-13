# Bug Hall of Fame

A rogues' gallery of the gnarliest bugs this codebase has shipped, how they
manifested, and what actually fixed them. Read this before touching input or
interrupt code; the same traps keep reincarnating.

---

## The ESC that ate your next keystroke (0.4.0)

**Symptom:** Pressing ESC or Ctrl-C to cancel an in-flight API call, then
immediately typing the next prompt, froze the session. Typing worked but Enter
never sent anything, the first character was silently swallowed, and the turn
kept running until it timed out.

**Root cause:** `hasPendingEscapeTail` decided whether a bare ESC means "cancel"
or "start of an arrow-key sequence" by polling for 250ms and reporting true if
*any* byte followed the ESC. So ESC followed by, say, `h` classified the `h` as
an escape-sequence tail. The interrupt never fired and the `h` was consumed by
the failed sequence match, never reaching the editor.

The kicker: the existing test suite never caught it. Every interrupt test used
the in-process provider stub, which detects interrupts synchronously in under
100ms. The real failure only surfaced against a live provider whose blocking
TLS `recv` holds the turn open, giving the user time to type into the
still-active turn.

**Fix:** Peek at the actual byte after ESC instead of just checking that
*something* is pending. Printable letters are never valid escape-sequence
continuations (only `[`, `O`, CR, digits, and `~` are), so ESC + typing now
cancels and the typed character survives. Poll window dropped from 250ms to
50ms since the byte-peek removes the whole false-positive class.

**Lesson:** A test harness that makes the bug mechanically impossible to hit is
a blind spot, not coverage. If the production path can block in a way the stub
can't, the stub isn't testing that path.

---

## The spinner that spun for eight hours (streamhttp write spin)

**Symptom:** After a tool call completed, 3code froze on a braille-spinner
frame with an ever-climbing `⧖ Ns` quiet counter. The process sat at 100%
CPU, one core, for hours. Typing did nothing; Ctrl-C did nothing. `ps`
showed state `R` (on CPU), not `S` (blocked).

**Root cause:** Reusing a cached TLS keep-alive connection that the server
had silently half-closed during the idle window between turns. The next
`callModel` posted its request via streamhttp's `sendRequest`, which
delegated to Nim stdlib `net.send`. `net.send`'s retry loop treats an
`SSL_write` return value of 0 as "0 bytes written, try again" and never
advances its write offset, so a half-shut TLS session (OpenSSL returns 0,
`SSL_ERROR_ZERO_RETURN`, on the peer's close_notify) made it loop on
`SSL_write` forever, each iteration churning OpenSSL's error-string
allocator (`ERR_clear_error` / `ERR_set_error` / `realloc`) and issuing a
zero-length socket write. `perf record` pinned 60%+ of CPU inside that one
`send` frame; `/proc/<pid>/task/<tid>/io` showed ~500k write syscalls/sec
with `wchar` frozen (zero-length writes).

The tool call had already finished and the model's follow-up request was
the one spinning, so the on-screen tool output and the `⧖` label were a
frozen snapshot of the last completed frame, not the live state.

**Fix:** streamhttp now sends over TLS through a bounded `sslSendAll` that
queries `SSL_get_error`: only `WANT_READ`/`WANT_WRITE` are retried (capped,
with a sleep), and every other non-progress return (`ZERO_RETURN`,
`SYSCALL`, real SSL error) raises so `callModel` drops the cached
connection and reconnects. Tagged streamhttp 0.3.2; the regression test
spins a TLS server that serves one response then closes, and asserts the
client's second request raises instead of looping.

**Lesson:** `SSL_write` returning `<= 0` is not bytes-written, it is
"query `SSL_get_error`." Any write loop that treats the raw return as a
progress count will spin on a half-dead connection. A cached connection is
a liability as well as a latency win: the cache must be dropped the moment
a write fails, and writes need a real bound, not an unbounded retry.

---

## The slurp that ate your scrollback one line at a time (0.5.0)

**Symptom:** During a reasoning-heavy turn (hy3, glm-5.x), committed
scrollback lines vanished one at a time, roughly one per 100ms, until whole
paragraphs of the answer were gone. The effect was visible only against live
reasoning providers; stubbed tests never reproduced it.

**Root cause:** `resizeRecent()`, a guard added to fix a footer-stacking bug
on terminal resize, added +1 to the erase-row walk-up in both `walkUp` and
`beginEditorRedraw` for a 400ms window after every SIGWINCH. The comment
claimed the extra row "sits inside the volatile region (the always-reserved
ticker/gap row), so it never reaches committed scrollback." That was false:
the footer's `rowsAboveEditor` already *includes* the gap row
(`1 + barWrapRows`), so the +1 walked above the gap into committed content.
Each 80ms spinner tick during the resize window erased one more committed
line. A terminal that fires SIGWINCH intermittently (tmux pane adjustments,
window-manager resizes) kept the window armed across many ticks, so the slurp
was sustained rather than a one-line nick.

The slurp branch's single-GUI-thread refactor, which collapsed the two
footer-painting threads into one to close a *different* race on
`paintedFooterRows`, did not touch this: the +1 overcount was always
geometry, never a torn read.

**Fix:** Removed the +1, the `resizeAtMs` field, and the now-dead
`resizeRecent`/`noteResize` machinery from both walk-up sites. The
footer-stacking bug the guard was added to fix is no longer reproducible
(the single-thread renderer and the test-grid cursor clamp handle it), so
this is a clean removal, not a tradeoff. A new tty test
(`test_slurp_resize_reasoning.nim`) fires SIGWINCH during a reasoning burst
and asserts no committed line is wiped in place across consecutive frames;
it fails with the +1 present and passes without it.

**Lesson:** A comment that asserts an invariant ("never reaches committed
scrollback") without naming the arithmetic that proves it is a load-bearing
assumption in disguise. `rowsAboveEditor` counting the gap row was the whole
bug: double-count a row you think you are sparing and the spare becomes an
extra victim. And a test that checks the symptom you fixed (footer stacking)
but not the invariant you violated (scrollback integrity) is a guard dog
watching the wrong door.

---

## The invisible space that failed every run (test-side, exit code 1)

**Symptom:** The tty functional suite reported 25/25 `[OK]` yet the test
binary exited 1. A non-fatal `check` inside the *passing* `queued prompt
typed during a turn` test printed `needle was hello` / `row was ❯ hello`
and tripped Nim's failed-check counter. The test never *failed* — it only
leaked a failed `check` — so the `[OK]` line and the exit code disagreed.

**Root cause:** A test-side assumption, not a program bug. The test types
`" world"` into a queued prompt editor one char at a time, accumulating
`acc` (`"hello"` → `"hello "` → `"hello w"` …) and asserting each step's
`acc` is on the cursor row. But the editor's word-wrap — `lineSpans` in
minline.nim — intentionally excludes trailing break-spaces from rendered
rows: `contentEnd` tracks "just past the last non-space," so editor text
`"hello "` renders as the row `"hello"` (no trailing space). The caret is
correctly placed *after* the space; the space is simply never drawn.

The misleading part: the check failure prints `row was ❯ hello`, which
*visually* looks like it contains `"hello"` — and it does. But the needle
was `"hello "` (len 6, trailing space), and `"hello " in "❯ hello"` is
false. The printed `needle was hello` drops the trailing space because
terminal output trims it, hiding the real mismatch. Hex-dumping the cursor
row at every loop step proved it: after the space, bytes are
`E2 9D AF 20 68 65 6C 6C 6F` (`❯ hello`); only once the next non-space char
`w` lands does the space appear (`❯ hello w`).

**Fix:** `requireVisibleEditorCaret` compares against the needle with
trailing whitespace trimmed (`needle.strip(leading = false)`), with a
comment citing the lineSpans invariant. No-op for the other callers (their
needles have no trailing whitespace). Binary now exits 0.

**Lesson:** A trailing space in an assertion string is invisible in both
the source and the failure message — the one place a human looks. When a
`check ... in row` fails but the printed row *looks* like it contains the
needle, suspect unprintable or trailing-whitespace bytes and hex-dump
before reasoning further. And: a green `[OK]` with a non-zero exit code is
itself a bug — a non-fatal `check` in a passing test is a silent failure
that will break CI gating.
