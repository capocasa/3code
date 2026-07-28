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

- A0 DONE (commit 069ff11): production reply filter in minline
  (consumeTerminalReplyImpl template, shape-validated CSI [?] nums R|c so
  CSI 1;5R modified arrows pass through); wired into readLine getCh +
  terminalHasPendingInput. terminaldbg slimmed to replyCaptureHook.
  minline_testutils Driver.run mirrors the filter (peek ttty Input queue,
  drop shaped replies). 3 new tests in test_minline (suite "terminal reply
  filtering"). All 18 core + 21 tty suites green.
- Note: filter is ASCII-burst based; a reply arriving byte-by-byte with
  gaps (poll misses mid-sequence) still leaks — accepted residual,
  terminals answer in one burst.
- Old code-review plan from main preserved at
  /tmp/old-cybernetic-plan-code-review.md (session-local!).
- Pre-existing: test_cli_args needs `3code` binary in cwd; skipped in
  suite runs, unrelated.
- NEXT: B1 ttty pairing validator.

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

- [ ] B1. Sync/pairing validator in grid.nim `feed`: generic paired-mode
  tracker (2026 now; table-driven for 2004/1049/25 later). Records
  violations: nested open, end-without-open, unclosed-at-EOF. Surfaced as
  `g.violations: seq[string]` (no behavior change to the grid itself).
  Unit test in ttty: crafted nested/unmatched 2026 streams produce
  violations; well-formed streams produce none.
- [ ] B2. xterm edge-case corpus: synthetic streams exercising
  wrap-at-last-column (print to col N-1, then CR/LF/ED variants),
  wide-char at right edge (CJK/emoji straddling), scroll-region bottom
  LF. Compare ttty vs xterm via compareToOracle; record divergences.
- [ ] B3. Fix ttty grid divergences found by B2 (expected: pending-wrap
  timing, wide-char edge). Each fix red→green against its corpus stream.
- [ ] B4. Release ttty 0.5.0 (tag, push, nimble install) so 3code picks
  it up.

### C. 3code wiring + closeout

- [ ] C1. Wire validator into tty_expect/ttty usage in 3code tests:
  after each tty test's frames, assert `violations.len == 0`. Catches
  malformed 2026 by proxy in every existing tty test.
- [ ] C2. Run full core+tty suites on xterm oracle path; if the user's
  xterm symptom reproduces as a conformance/validator failure, diagnose
  from there; else report to user for a live re-check.
- [ ] C3. Update HANDOVER.md (closed bug + new instruments); commit.
- [ ] C4. Final review: full diff vs plan, full test matrix, clean tree.
