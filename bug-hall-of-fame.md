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
