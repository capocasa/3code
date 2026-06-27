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
