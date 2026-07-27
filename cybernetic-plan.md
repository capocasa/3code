# Cybernetic Plan: Code Review Cleanup

## Context

Full code review of 3code (2026) found the codebase largely healthy but
carrying unfinished migrations, rule violations, and test-design debt.
The review findings are in `guidelines-updated.md` (read it first); this
plan is the ordered work to bring the tree into compliance.

Key facts a fresh context needs:

- **Terminal ownership:** `src/threecode/engine.nim` is the sole layout
  owner (walk-up model: `editorRowsAboveCursor + paintedFooterRows +
  viewport/live rows`). `src/threecode/terminal.nim` is its byte layer.
  `src/threecode/fatprompt/runtime.nim` still contains pre-engine paint
  helpers that bypass this model (lines ~723-852, 1055-1096:
  `paintBarPrompt`, `paintBarBelow`, `clearBarPrompt`, `repaintBarPrompt`,
  `paintPromptOnly` x2, `paintInitialBar`, `paintInitialPrompt`,
  `enterPromptInput`, `resetPromptInputAfterEmpty`). They are called from
  runtime.nim itself and `threecode.nim`.
- **History appends:** `transcript.nim` builds `TranscriptItem`s;
  `engine.appendTranscript` / `runtime.commitTranscriptBytes` commit them.
  Direct scrollback writers remain: `ui.nim` (wizard status lines,
  `hintLn`/`errLn` from display.nim templates), `display.nim`
  (`cmdResponse`, `cmdError`, `renderHelp`, replay emitters),
  `turns.nim:648-650` (cwd-gone message), `threecode.nim:536-552,624`
  (resume banner, replay bar, no-provider line).
- **Wizard modal protocol:** `wizardReadLine` in runtime.nim routes modal
  prompts through the input thread; `inputModalActive` freezes renderer
  hooks. Wizard post-writes (`verifying... ok`, `added <name>`) are plain
  stdout writes that are safe only because of this flag. Design target:
  wizard emits status via transcript items after `wizardFinish`.
- **Duplicated helpers:** `trimTranscriptTail` exists in both
  `transcript.nim` and `turns.nim:17-19`. `resetSubmittedEditor` logic is
  duplicated between `threecode.nim:600-611` (clearSubmittedCommandEditor)
  and `runtime.resetEditorRowModel`.
- **Test violations:** raw-byte assertions in
  `tests/tty/test_tty_functional.nim:813-815` (color), ~1729-1790
  (sync-payload `\x1b[J` scan), `tests/core/test_ticker_cleanup.nim:44-51`
  (`\x1b[J` rfind). Also: several PTY tests in tests/tty use the
  in-process stub which cannot reproduce blocking-network behavior (hall
  of fame rule); audit which interrupt tests need mock_server latency.
- **Test harness quirk:** test blocks not inside the `suite` block
  silently never run (tests-notes.md). `tests/megatest.nim` is
  uncommitted/unused; decide its fate.
- **Dead code:** `bufprompt.nim` is tested but not wired into the REPL.
- **streamhttp:** sound overall; remaining risks are blocking first DNS
  resolve, and close-vs-concurrent-recv ordering being undocumented at
  call sites. `httpclient` still imported by api.nim, compact.nim,
  web.nim, update.nim for non-streaming GETs.
- **Build/test:** `nimble test` runs testament over tests/*/; run a single
  file with `nimble test tests/tty/test_tty_functional.nim` (testament `r`
  per file). Build: `nimble build` puts the binary in place (project
  convention says also `nimble install` after builds, but not after every
  commit). Fixture-driven workflow per `.agents/development-guide.md`.

## Current state

Steps 1-6 DONE and committed (each commit is on main, tests 100% green
after each):

1. f9611cf dedup trimTranscriptTail (now in transcript.nim only) and
   editor row reset (now `resetEditorRowModel` exported from runtime.nim,
   used in threecode.nim 3 sites + runtime submit path).
2. 024b9f0 deleted bufprompt.nim + tests/api/test_bufprompt.nim (input
   thread's autosend queue is the live mechanism; bufprompt was unwired).
   Also updated a stale comment in netthread.nim.
3. d4221a7 cwd-gone (turns.nim) and no-provider (threecode.nim) now go
   through the transcript path.
4+5. 821a55f command emitters return strings. NEW string emitters in
   display.nim: `hintS/hintLnS/noteLnS/errS/errLnS/cmdResponseS/cmdErrorS/
   styleText`, `profileLinesS`, `renderHelpS`, `showToolS`, `listToolsS`,
   `printSessionListS`, `skillLoadedBytes`, `renderAssistantContentBytes`,
   `assistantBulletBytes`. config.nim: `experimentalGateText`. All `cmd*`
   procs in ui.nim now return `string`. The handleCommandResult dispatch
   accumulates `body` (templates `resp`/`respErr`), no captureStdoutWrites.
   Modal path (ckModal) returns `wizardBody` in CommandResult; threecode.nim
   cdModal branch commits it via commitTranscriptBytes after wizardFinish.
   Usage-error case (`:provider add <extra>`) returns cdTranscriptResult.
   profileLinesS: non-bold has NO leading pad, bold has 2-space pad (this
   was a fixture-visible bug during the work; keep it).
6. 91e3da5 captureStdoutWrites + writeTranscriptWithFatPrompt* templates
   DELETED from runtime.nim. All former callers now build strings and call
   commitTranscriptBytes(bytes, true) directly.

7. e6fb386 legacy fatprompt paint helpers deleted from runtime.nim
   (`paintBarPrompt`, `paintBarBelow`, `clearBarPrompt`,
   `repaintBarPrompt`, `paintPromptOnly` x2, `paintInitialBar`,
   `paintInitialPrompt`, `enterPromptInput`,
   `resetPromptInputAfterEmpty` plus terminal.nim's
   `enterPromptInput`/`resetPromptInputAfterEmpty` byte-layer procs).
   Replacements: ui.nim empty-submit now repaints the current
   `footerFrame(fatPromptState)` via `termengine.renderFooter` (ui.nim
   imports `engine as termengine`); `paintInitialPrompt` keeps one live
   exported entry — anchored path renders the frame through the engine,
   pre-input-thread path keeps the raw `\n\x1b[?25l` +
   `promptOnlyResetBytes` paint. `paintBarPrompt`/`clearBarPrompt` are
   now module-private (writeRendered legacy branch still uses them);
   `writeLiveSegment`'s liveBarAtCursor clear calls renderFooter
   directly. NO fixture churn: the anchored renderFooter clears are
   byte-identical to the old ClearBarPromptBytes when
   paintedFooterRows==0 (already covered by engine.renderLiveContent).
   Full suite 56 PASS 0 FAIL.

8. d048c47 measure-not-effect tests fixed. test_tty_functional.nim:
   429 notice + stub-model color contract now asserts `cellFg ==
   colMagenta` (+ not bold via `hasAttr`) and `cellFg ==
   colBrightWhite` on the ttty grid (imports `ttty/grid`; grid retains
   scrolled-off rows). The bash-viewport flicker scan now works on
   recorded frames: marker vanish-then-return on the same row with
   neighbours unchanged = flicker; raw sync-payload ESC[J scan deleted.
   test_ticker_cleanup.nim: replays the captured spinner session onto a
   ttty grid seeded with one committed scrollback line; asserts the
   committed line survives and no ticker remnant (`test`) remains;
   dropped the `\x1b[J` rfind + cursor-up byte checks. ttty hasAttr
   exists in ~/p/ttty grid.nim (SgrAttr distinct uint16).

9. Interrupt/cancel test audit (no code change; decisions recorded).
   tests/tty/test_interrupt_network_connect.nim already drives the real
   non-stub transport against tests/mock_server.nim with induced stalls:
   msSilentAfterAccept (connect-phase Ctrl-C), msSlowStream (mid-body
   Ctrl-C), msSlowStreamNoUsage (interrupt before usage event),
   msStallAfterDone (teardown close hang), plus the quiet-watch
   (QuietTooLongMs) case. The blocking-mid-recv class the hall-of-fame
   rule targets is covered there.
   Remaining stub-based interrupt tests were checked against the stub
   source (testdata/stub/provider.nim): preStreamDelayMs and
   contentChunkDelayMs sleep loops poll isInterrupted() every 50-100ms
   and raise "interrupted by user", so these tests DO exercise the
   interrupt handshake; what they cannot exercise is a stuck syscall,
   which the mock server cases own. Per-test verdicts:
   - test_interrupt_prestream_freeze (ESC/Ctrl-C, preStreamDelayMs):
     KEEP. Subject is the input-thread/editor prompt contract after
     cancel (caret col 2, glyph on caret row, follow-up accepted).
   - test_429_typing_during_backoff (Ctrl-C mid-backoff, typed text):
     KEEP. Subject is buffered-editor text preservation, a pure
     input-side contract; network is irrelevant.
   - test_tty_functional quiet_cancel ESC/Ctrl-C (waitForTestContinue):
     KEEP. Same prompt-contract class as prestream_freeze.
   - test_resize_ticker / test_slurp_resize_reasoning /
     test_spinner_race_stress Ctrl-Cs: KEEP. Cleanup/stress triggers,
     not blocking-recv assertions.
   - test_quit_signals: KEEP. Input-thread Ctrl-D/Ctrl-C flag lifecycle.
   No mock_server 429-retry scenario added: the retry-cancel handshake
   is timing-driven (polls isInterrupted), and the connect/recv-stall
   variants of cancel are already covered by the four mock scenarios.

10. DONE, one module per commit, full suite 56 PASS after each:
    - 6693699 threecode.nim: resume-banner pyramid flattened
      (restoredDraft hoisted before resume branch, single
      `runInitialPrompt` guard), handleBufferedAfterTurn early-exits on
      empty queue.
    - e4ebfbc engine.nim: renderFooter/renderToolViewport/
      renderLiveContent/repaintLiveContent no-editor branch early-exits
      (byte order preserved: SyncBegin/hide-cursor/bytes/note/SyncEnd/
      flush/lastPaintedWidth identical per branch); appendTranscript's
      two anchored branches extracted to appendTranscriptLiveAnchored/
      appendTranscriptFloating + shared writeTranscriptItem. Watch out:
      writeTranscriptItem needs `e: var TerminalEngine` (mutates
      hasScrollback); nimble build on the main binary did NOT surface
      that because engine is compiled per-test too — always run a test
      file before the full suite.
    - 05e1a15 api.nim: streamConnect conn-cache branch inverted to
      guard form. Remaining deep indents in api.nim are signature
      continuations (buildStreamAssistantMsg) and already-early-exit
      parseUsage/extractErrorMsg — left alone.
    - 2ad8ca6 ui.nim: verifyAndReport helper extracted from the three
      wizard verify blocks; model loops now read error/error/verify-
      return with bad cases falling through to the retry prompt;
      inferred-provider branch inverted. Output bytes identical.
    - session.nim: NO CHANGE. tryCreateLockFile (posix branch cited in
      the review) already uses early-exit; its :281 indent is a
      winlean parameter continuation, and :402 likewise. Nothing to
      flatten without churning byte-identical code for cosmetics.
    - ce6c228 minline.nim: insertText insert-mode fast path
      early-returns; replace-mode body flush left. The :1538 cite is a
      parameter continuation in the readLineWith keystroke dispatcher,
      which is already in early-exit `continue`-chain style.

ALL 15 STEPS DONE. Final full `nimble test` run is the last gate;
then this plan is complete.

Key gotchas learned:
- `func` cannot read palette `var`s (BrightWhiteFg etc); string emitters
  that use them must be `proc`.
- `nimble build 2>&1 | grep -icE error` miscounts; use exit code of
  nimble build itself.
- `nimble test` full suite takes ~7 min (tty stress tests are slow);
  run targeted files with `nimble test tests/tty/test_x.nim`.
- testament `r` needs a .nim FILE not a dir: `nimble test tests/core/`
  fails; use `nimble test` (all) or a specific file.
- Pre-existing untracked files in working tree: leave alone.

## Steps

1. [x] **Delete duplicated helpers.** Remove `trimTranscriptTail` from
   `turns.nim` (import from transcript.nim). Unify the two
   reset-submitted-editor implementations into one exported helper in
   `runtime.nim` used by both `threecode.nim` and the runtime submit path.
   Build + run tests/core + tests/tty quick pass.

2. [x] **Decide bufprompt.nim fate.** Either wire the buffered-input API
   into the REPL (check git history for why it was unwired) or delete the
   module and `tests/api/test_bufprompt.nim`. Record the decision here.

3. [x] **Route cwd-gone and no-provider messages through the transcript
   path.** `turns.nim:644-651` and `threecode.nim:622-626` write directly;
   convert to harness items via `writeTranscriptWithFatPrompt` (the
   `onTurnInterrupted` pattern). Note the cwd-gone path calls `quit()`
   right after, so ordering matters: write first, then quit.

4. [x] **Convert command results to controller-committed items.** In
   `ui.nim`, `handleCommandResult` currently captures stdout from
   `cmdProvider*`/`cmdResponse`-style emitters via `captureStdoutWrites`
   (ui.nim:969). Refactor command emitters to return body strings
   (view-style) instead of writing; keep `captureStdoutWrites` only for
   the replay emitters in display.nim until step 6. `threecode.nim`'s
   command branch then commits echo+body via one `commitTranscriptBytes`
   call (it already does; only the producers change).

5. [x] **Wizard status via transcript items.** Change the provider wizard
   (`ui.nim` `promptNewProvider`/`promptEditProvider`/`bootstrapProvider`)
   so status lines (`verifying... ok`, `added <name>`, model lists,
   `saved to ...`) are returned in the `CommandResult` body (or appended
   by the controller after `wizardFinish`) instead of written mid-modal.
   This removes the load-bearing dependence on `inputModalActive` for
   stdout correctness. Reproduce with
   `tests/tty/test_provider_wizard_cancel.nim` and the add/edit PTY
   tests; update fixtures deliberately.

6. [x] **Retire captureStdoutWrites.** Convert remaining wrapped
   formatters (transcript.nim:78, turns.nim:197,218, runtime.nim:909,
   display.nim replay paths) to return strings. Delete the template and
   its Windows fd-dup implementation. Update tests that depended on
   capture behavior.

7. [x] **Delete legacy fatprompt paint helpers.** Move all callers of
   `paintBarPrompt`/`paintBarBelow`/`clearBarPrompt`/`repaintBarPrompt`/
   `paintPromptOnly`/`paintInitialBar`/`paintInitialPrompt`/
   `enterPromptInput`/`resetPromptInputAfterEmpty` onto
   `FooterFrame`+`renderFooter` (or `commitTranscriptBytes`), then delete
   the helpers from runtime.nim. This is the biggest step; expect fixture
   churn in tests/tty. Follow the development-guide loop: describe each
   visual change, reproduce in the shakedown, then edit fixtures
   deliberately.

8. [x] **Fix measure-not-effect tests.** Replace raw-byte assertions:
   - test_tty_functional.nim:813-815: assert grid cell fg colors
     (ttty `cellFg`) for the 429 notice (colMagenta) and stub-model
     (colBrightWhite).
   - test_tty_functional.nim:~1729-1790 sync-payload scan: assert via
     frame diffs that no frame shows the viewport blanked-then-redrawn
     (grid-level invariant).
   - test_ticker_cleanup.nim: assert final grid state has no ticker
     remnant and caret in editor, drop the `\x1b[J` rfind.
   If ttty's Grid lacks needed accessors, add them to ~/p/ttty (it has
   `cellFg` already; verify color mapping).

9. [x] **Audit interrupt tests for stub-induced blindness.** List
   tests/tty interrupt/cancel tests; for each, determine whether it can
   still pass when the provider blocks mid-recv. Where the in-process
   stub makes blocking impossible, port the test to `mock_server.nim`
   with induced latency (see tests/stream tests for latency patterns).
   Record per-test decisions here.

10. [ ] **Reduce nesting in the worst offenders.** Apply early-exit
    style to: `threecode.nim` main REPL loop (~20 levels at :542),
    `engine.nim` renderFooter/appendTranscript, `api.nim` request-build
    region (:152), `ui.nim` wizard loops, `session.nim` (:281),
    `minline.nim` (:1538). One module per commit. No behavior change;
    run full tests after each.

11. [~] **Nim idiom pass.** Convert side-effect-free procs to `func`
    where trivially eligible (formatters in display.nim,
    fatprompt/rendering.nim, util.nim). Split `session.nim` (1240 lines)
    and `minline.nim` (1695) if natural seams exist; record the seam or
    the reason not to split.

    DONE (fb3199a): 26 procs in util.nim (utf8ByteCut/End,
    sanitizeUtf8, clipMiddle, humanBytes/Tokens, detectMdHeader,
    isMdFenceLine, isAtBoundary, applyInlineMd, visibleWidth, wrapAnsi,
    charWrapAnsi, bannerWrapRows, isMdTableRow, parseMdRow, isMdSepRow,
    renderMdTable, tokenSlot, stripPreamble, replaceFirst,
    isBinaryContent, looksLikePath, levenshtein(+Capped)) and 14 in
    fatprompt/rendering.nim (markerText, splitLogicalLines, wrapPlain,
    cellWidth, wrapMarked, hasNonNewlineBytes, hasElapsedSuffix,
    labelCells, barWrapRows, clampToWidth, editorRows/Height,
    bashVisibleRows, frameRows/Text) converted. Left as proc:
    palette-reading byte emitters (spinnerBarBytes, liveBarBytes,
    *FooterBytes — func cannot read the palette `var`s), display.nim's
    string emitters (same palette reason, already recorded in
    gotchas), addUserEcho/formatUserPromptItem (mutate var params /
    call hook chains the compiler flags as side-effectful).
    Split decision: NOT SPLIT. session.nim's sections (paths, index,
    drafts, locks, record parser, writer, save/load, listing) are
    interdependent — the writer and parser share the Record format and
    emitRecord/parseRecords twins; the lock procs share the
    activeLockPath module state. A mechanical split would move
    privates to exports across modules with no encapsulation gain.
    minline.nim's marker sections (pure helpers, render, edit ops,
    history, keymap, completion, driver) are dense closures over the
    LineEditor object; `handleEscape`/`readLineWith` reference nearly
    every section. Both files read top-to-bottom in dependency order;
    the 1200/1700-line size is a symptom of one-editor/one-format,
    not of mixed concerns.

12. [x] **streamhttp documentation + DNS step.** In ~/p/streamhttp:
    document the shutdown-then-close ordering requirement on `close` at
    the proc and in README. Add a bounded resolver thread for the
    blocking first DNS resolve (or record the decision to defer with
    rationale). In 3code, verify every `close` call site follows the
    ordering. Run streamhttp's nimble test.

    DONE (streamhttp 95126b6): close doc comment now states the
    ordering requirement (shutdown(fd) first so a concurrent recv
    unwinds, then close; single-threaded owners need nothing); README
    gained "Closing a connection" and "DNS" sections saying the same.
    3code call-site audit: all StreamConn closes are safe —
    closeCachedStreamConn is only called after shutdownCachedStreamFd
    (Ctrl-C/quiet-watch) or from the owning network worker itself
    (stale-conn retry, interrupt observed in the read loop), and
    api.nim:1947's verify defer closes a conn only its own thread ever
    touched. The `client.close()` sites in api/compact/web/update are
    std/httpclient, not streamhttp (step 13 owns them).
    DNS decision: DEFER the bounded resolver thread. streamhttp's own
    comment already marks one blocking first-resolve-per-host as the
    documented floor; a resolver thread + completion channel would be
    the first new synchronization pattern in the transport (violates
    guideline §6's "no new handshakes"), and the real-world exposure is
    a hang during the FIRST connect to a host with black-holed DNS —
    rare, and the user still has SIGINT-at-process-level (signalCleanup)
    as the escape hatch. Recorded, not implemented.
    streamhttp nimble test: 26 [OK], 0 [FAILED].

13. [x] **httpclient migration decision.** Decide: migrate the four
    non-streaming httpclient users (api verify/fetchModels, compact,
    web, update) to streamhttp identity reads, or bless httpclient for
    one-shot GETs and remove the guideline item. Record decision and
    rationale here; implement if migrating.

    DECISION: bless httpclient for the four one-shot users; remove the
    migration backlog. Rationale:
    - These are bounded whole-body request/response calls with explicit
      timeouts (10-120s): fetchModels (20s GET), compact summarize
      (120s POST, non-stream by design), web search/fetch (20-30s),
      update check/download (10-60s). None is an SSE/streaming path;
      the property streamhttp exists for (chunk-at-a-time reads) buys
      them nothing.
    - streamhttp's one-shot path is less capable for these, not more:
      httpclient handles redirects (web.nim hits them routinely), and
      streamhttp's Scope section explicitly rules redirects out.
    - The bad-network bug class the guideline cares about (stuck TLS
      recv, uncancellable teardown) belongs to the long-lived streaming
      conn, which is 100% streamhttp with the fd-shutdown hooks. The
      one-shots are interruptible by process-level SIGINT and bounded
      by their timeouts.
    - Migrating would replace four boring working call sites with new
      code exercising streamhttp's least-tested paths (identity reads
      at 60-120s), for guideline purity only.
    Guideline §7 updated: the "migration backlog" sentence is replaced
    by the blessing. The rule that remains load-bearing: no NEW
    httpclient uses, and no second client on any streaming path.

14. [x] **megatest.nim + stray test files.** Decide fate of uncommitted
    `tests/megatest.nim` (wire it into nimble test or delete). Remove or
    restore `tests/tty/test_z_exitcode_probe` (present without .nim?).
    Verify every test block lives inside a `suite` block (tests-notes.md
    silent-skip trap): grep for `^test "` at column 0 in tests/tty.

    DONE: tests/megatest.nim DELETED. It was testament's stale
    megatest-mode artifact (hardcoded nimcache import paths, referenced
    the long-deleted test_bufprompt.nim); the nimble test task pins
    `--megatest:off` (unittest stdout would interleave into garbage
    under megatest), so it can never be wired in without a harness
    change nobody wants. tests/tty/test_z_exitcode_probe (and ~20
    sibling directories without .nim) are compiled-test artifacts, left
    untracked as before. Silent-skip audit: zero `^test "` at column 0
    across tests/{tty,core,api,config}; every test block is inside a
    suite. Full suite 56 PASS 0 FAIL after the deletion.

15. [x] **Final sweep.** Grep audits: no `\x1b[` outside
    terminal/engine/minline/rendering; no `stdout.write` in
    controller modules except via display templates returning through the
    transcript path; no remaining `captureStdoutWrites`; no duplicate
    helper names across modules (`grep -rn "proc <name>"`). Update
    `.agents/design.md` module map where reality moved (engine.nim is
    missing from the map). Full `nimble test` green. Update
    guidelines-updated.md if any rule proved wrong.

    DONE: `captureStdoutWrites` fully gone. No duplicate helper names
    (trimTranscriptTail, resetEditorRowModel, verifyAndReport,
    writeTranscriptItem, appendTranscriptLiveAnchored,
    plainCommandBodyBytes all single-definition; the two
    footerFrameBytes are deliberate overloads on distinct types).
    design.md module map gained engine.nim as sole layout owner.
    Remaining greps are pre-existing accepted classes, not regressions
    from this cleanup: fatprompt/runtime.nim keeps a handful of
    byte-level writes (input-thread bracketed-paste toggle, caret
    show/hide, paintInitialPrompt's pre-engine raw paint — flagged in
    step 7 as the live entry point; removing them is a future design
    change, not a sweep item), and util.nim/display.nim emit `\x1b[`
    inside ANSI-styling formatters (guideline §4 explicitly allows
    byte-level assertions/output for pure ANSI emitters; §2's rule
    targets cursor/erase moves, which none of these perform).
    ui.nim/threecode.nim `stdout.write` sites are the accepted
    newline/modal cases. guidelines-updated.md needed no corrections
    beyond the step-13 httpclient blessing: no rule proved wrong.
