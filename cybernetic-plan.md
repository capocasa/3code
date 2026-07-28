# Cybernetic plan: terminal-fidelity hardening (ttty + 3code)

## Context

The foot/ghostty line-math bugs (fixed, `97b9dba` on `~/p/3code/linebugs`)
exposed a test-blindness family: ttty's grid shares 3code's terminal
assumptions, so model-vs-physical desyncs are invisible to every PTY test.
User ALSO saw a similar symptom on xterm post-fix — so a second,
non-2026 bug may exist; the xterm conformance corpus (step A2) is the
instrument to find it.

Bug classes (agreed with user):
1. Paired-state modes the grid doesn't validate (2026 was the dangerous one).
2. Terminal reply bytes (`CSI row;col R` etc.) leaking into the editor as
   phantom input — hit live by the terminaldbg probe.
3. Rendering-semantics divergence (wrap-at-last-col timing, wide-char at
   right edge, resize reflow) between real terminals. Curable by proxy:
   calibrate ttty against a real-terminal oracle, then ttty catches app
   divergence in ordinary tests.

Strategy (agreed): xterm only for now. Profiles/ghostty deferred.

Repos:
- ttty: ~/p/ttty (0.4.0; grid src/ttty/grid.nim `feed` parses CSI;
  oracle src/ttty/x11oracle.nim; conformance src/ttty/conformance.nim;
  corpus tests/corpus/*.raw; test tests/test_x11_conformance.nim;
  `nimble conformance` runs it; nimble-installed so 3code picks it up)
- 3code: ~/p/3code/linebugs branch linebugs. Build:
  PATHS=""; for p in unicodedb streamhttp ttty tinotify procbox; do
    PATHS="$PATHS --path:$(nimble path $p | tail -1)"; done
  nim c -d:ssl --threads:on --path:src $PATHS -o:build/3code_real src/threecode.nim
  (add -d:providerStub -o:build/3code_stub for the stub)
  Saved PATHS in /tmp/paths.txt (session-local; regenerate if gone).

Key locations:
- minline.nim: `isEscapeTailByte` ~285; `terminalHasPendingInput` ~1249;
  posix getCh in readLine ~1730; hooks `inputInterceptHook`/`pushedBack` ~66.
- engine.nim: probe calls at 512 (probeDetail), 557, 635 (probeErase).
- terminaldbg.nim: `dsrIntercept` ~45, `queryCursorPos` ~115.

## Current state

- A0 DONE (3code 069ff11): production reply filter in minline
  (consumeTerminalReplyImpl template, shape-validated CSI [?] nums R|c so
  CSI 1;5R modified arrows pass through); wired into readLine getCh +
  terminalHasPendingInput. terminaldbg slimmed to replyCaptureHook.
  minline_testutils Driver.run mirrors the filter. 3 new test_minline
  tests. Residual: byte-by-byte reply arrival with gaps still leaks
  (accepted; terminals answer in one burst).
- B1 DONE (ttty fefd15b): grid validates DEC 2026 pairing; violations in
  g.violations + checkStreamClosed. 5 unit tests.
- B2+B3 DONE (ttty e55be8b): 8 edge-case conformance streams; exposed and
  fixed 3 xterm divergences (ED clears pending-wrap + overwrite last
  cell; ED0 blanks not truncates; deferred-wrap re-arm). 14/14 conform.
- B4 DONE: ttty 0.5.0 tagged/pushed/nimble-installed (0.3.0 and 0.5.0
  coexist; nimble path returns 0.5.0 first — use `head -1` not `tail -1`).
  3code requires ttty >= 0.5.0 (ca79b29).
- C1 DONE (3code ca79b29): tty_expect.close asserts grid violations==0.
  Gate red-checked (nested stream flags 2 violations); all 21 tty tests
  green with gate armed.
- C2 PARTIAL: user's xterm symptom NOT reproduced by any instrument. The
  fixed bugs were 2026-specific (xterm ignores 2026) so an xterm sighting
  is likely a DIFFERENT bug. Capture path: tty_expect `s.raw` holds the
  exact stream; replay via ttty compareToOracle. NEEDS USER: re-check
  with build/3code_real (has 97b9dba + A0 filter), and if reproducible
  on xterm describe exact trigger.
- Old code-review plan preserved at /tmp/old-cybernetic-plan-code-review.md.
- test_cli_args needs `3code` binary in cwd; pre-existing, skipped.
- C3 DONE (c6bb211). C4 DONE: full diff reviewed (one stale comment
  fixed, 58502f1); all suites green. Remaining open item: user xterm
  re-check (C2). Plan complete pending that.

## Steps

### A. 3code (linebugs branch)

- [x] A0a. Reply-drop hardening in minline: move DSR-reply recognition from
  terminaldbg's debug hook into a production filter. Concretely: in the
  posix readLine getCh and in `terminalHasPendingInput`, when ESC '['
  starts a sequence whose final byte is 'R' (cursor-position reply) or
  'c' (DA reply), drop the whole sequence instead of feeding it to the
  editor. Keep `inputInterceptHook` as the pre-filter so the probe still
  stashes replies. Verify: core+tty suites green.
- [x] A0b. Simplify terminaldbg to a thin stash/log layer on the production
  filter (remove duplicated parsing in dsrIntercept). Verify: build +
  suites green.
- [x] A0c. Regression test: tests/core/test_minline.nim style — feeding a
  DSR reply byte stream into readLineWith yields no phantom input and the
  reply is consumed. Red→green against pre-A0a code if feasible.

### B. ttty

- [x] B1. Sync/pairing validator in grid.nim `feed`: generic paired-mode
  tracker (2026 now; table-driven for 2004/1049/25 later). Records
  violations: nested open, end-without-open, unclosed-at-EOF. Surfaced as
  `g.violations: seq[string]` (no behavior change to the grid itself).
  Unit test in ttty: crafted nested/unmatched 2026 streams produce
  violations; well-formed streams produce none.
- [x] B2. xterm edge-case corpus: synthetic streams exercising
  wrap-at-last-column (print to col N-1, then CR/LF/ED variants),
  wide-char at right edge (CJK/emoji straddling), scroll-region bottom
  LF. Compare ttty vs xterm via compareToOracle; record divergences.
- [x] B3. Fix ttty grid divergences found by B2 (expected: pending-wrap
  timing, wide-char edge). Each fix red→green against its corpus stream.
- [x] B4. Release ttty 0.5.0 (tag, push, nimble install) so 3code picks
  it up.

### C. 3code wiring + closeout

- [x] C1. Wire validator into tty_expect/ttty usage in 3code tests:
  after each tty test's frames, assert `violations.len == 0`. Catches
  malformed 2026 by proxy in every existing tty test.
- [ ] C2. Run full core+tty suites on xterm oracle path; if the user's
  xterm symptom reproduces as a conformance/validator failure, diagnose
  from there; else report to user for a live re-check.
- [x] C3. Update HANDOVER.md (closed bug + new instruments); commit.
- [x] C4. Final review: full diff vs plan, full test matrix, clean tree.
