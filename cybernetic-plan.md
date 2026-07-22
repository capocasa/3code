# Cybernetic Plan: re-enable Windows-disabled tests (adapt, don't skip)

## Context

Windows is a primary target on equal footing with Linux and macOS. Today 27
test files carry `disabled: "win"`. The OSX work (this branch, commit
eec8d80) took the "adapt to the OS, just as meaningful" path: it removed
`disabled: "osx"` from 17 of 18 tty files and hardened the harness's blocking
calls rather than loosening assertions. The goal here is the same for Windows
— remove every `disabled: "win"` that can be made genuinely meaningful on
Windows, and leave a precise, documented fallback only for what truly cannot.

The 27 `disabled: "win"` files split into three classes with distinct root
causes (confirmed by reading source this session):

### Class A — OS-assumption in the test, not the harness (9 files)

The tests assume POSIX env isolation that the production code does not honor
on Windows. Three concrete root causes, all in `src/threecode/util.nim`:

1. **`userDataRoot()` ignores `XDG_DATA_HOME` on Windows** (util.nim:298).
   The POSIX branch reads `getEnv("XDG_DATA_HOME")` (line 300); the Windows
   branch (line 298) is bare `getConfigDir() / "3code"`. Tests that set
   `XDG_DATA_HOME` to a temp dir for isolation leak into real `APPDATA`.
   Blocks: `tests/core/test_session.nim`, `tests/core/test_cli_args.nim`
   (the `-l` and skills-dir suites), `tests/core/test_util_extra.nim` (the
   `userDataRoot`-derived asserts).
2. **`userConfigRoot()` ignores `XDG_CONFIG_HOME` on Windows** (util.nim:285).
   Both branches use `getConfigDir()`. On Linux `getConfigDir()` honors
   `XDG_CONFIG_HOME`; on Windows Nim's `getConfigDir()` returns `APPDATA` and
   ignores it. So `test_update.nim`'s `putEnv("XDG_CONFIG_HOME", ...)` is
   silently ignored on Windows. Blocks: `tests/core/test_update.nim`.
3. **`collapseHome()` uses `/` separators** (util.nim:807). On Windows
   `getHomeDir() / "x"` yields backslashes, and `collapseHome` strips `/`
   only, so `~/src/test.nim` assertions fail. The proc itself is correct
   (path separator agnostic via `getHomeDir()` prefix match), the test
   expectations are not. Blocks the `collapseHome` suite in `test_util_extra`.

Fix: honor the XDG overrides on Windows too (mirrors the macOS XDG fix from
b7ea0f0, same rationale: "makes the data root redirectable for tests; the
platform default is unchanged when the variable is unset"). This is a source
fix that *enables* correct test isolation, not a test workaround.

Files (4): `test_session.nim`, `test_update.nim`, `test_util_extra.nim`,
`test_cli_args.nim` (already has `when defined(windows):` branches for the
`-l` runIn proc; the XDG source fix makes them actually isolate).

### Class B — simulated-terminal tests feeding platform-wrong key bytes (2 files)

`test_minline.nim` and `test_history.nim` drive the editor through
`tests/minline_testutils.nim`'s `Driver`, which pushes bytes into an in-process
`ttty` terminal (NOT a real PTY, NOT `_getch`). The Driver hardcodes XMod
escape sequences (`KeyUp = @[27,91,65]`) imported from `ttty/input.nim`.

The editor's decode tables are platform-conditional (`src/threecode/minline.nim`):
- `ESCAPES`: POSIX `{27}`, Windows `{0, 22, 224}` (the `_getch` extended-key prefix).
- `KEYSEQS`: POSIX `@[27,91,68]` (ESC [ D), Windows `@[224,75]`.

So on a Windows build the editor expects `@[224,75]` for Left, but the Driver
pushes `@[27,91,68]`. The leading `27` is not in Windows `ESCAPES`, so it's
treated as a bare char, not an escape prefix — cursor-move subtests misdecode.

The test path never touches `_getch`: `Driver.run` overrides `getCh` to read
from `d.terminal.read()`. So the tests are correctly testing editor *behavior*
(cursor movement, history nav), which is identical cross-platform; only the
*byte encoding the test feeds* must match the platform's `KEYSEQS`.

Fix: make the Driver's key constants read from `minline.KEYSEQS` at runtime
instead of hardcoding XMod. `KEYSEQS` is already a public threadvar, so the
Driver emits the exact bytes the platform build decodes. This makes the tests
meaningful on every platform: same behavior assertions, platform-correct input.

Files (2): `test_minline.nim`, `test_history.nim` (edit `minline_testutils.nim`).

### Class C — API/shell subprocess tests (3 files)

- `tests/api/test_api.nim` — the "request shaping" and "xml tool_call fallback"
  suites (~20 tests) are pure in-process function checks (applyStreamingOptions,
  applyReasoning, etc.) with no subprocess. The autosend/probe tests spawn a
  child nim compiler with `--threads:on`, documented as flaky on Windows runners.
  Fix: enable the whole file; the pure suites run on Windows unchanged. The
  probe tests use `execCmdEx("nim c ...")` which works on Windows git-bash.
  Re-enable; if a probe is genuinely flaky on Windows CI it gets a targeted
  `when defined(windows): skip()` with a precise comment, but prefer running.
- `tests/stream/test_streamexec.nim` — `runStreamingBash` shells out. On
  Windows it resolves the bundled MSYS2 bash (`%LOCALAPPDATA%\3code\msys64`),
  absent on CI runners (exit 127). The github-actions `windows-latest` image
  ships git-bash at `C:\Program Files\Git\bin\bash.exe`. Assess: can
  `resolveBash()` fall back to git-bash on CI? If yes, the tests run meaningfully
  (they assert on streaming line semantics, which bash provides regardless of
  source). Decision recorded in step.
- `tests/stream/test_netthread_blocks.nim` — thread + socket timing test. The
  StuckServer uses `net` sockets + a thread; the blocker cited is "timing
  flakiness under load." This is the same class of harness-load issue the OSX
  work bounded (poll with timeout vs blocking read). Assess whether it runs as-is.

### Class D — real-subprocess PTY tests (18 files, the tty suite)

All 18 `tests/tty/test_*.nim` drive the real `3code` binary through a PTY via
`tests/tty_expect.nim`, which is POSIX-only (`openpty`/`fork`/`execv`/
`waitpid`/`kill`/`TIOCSWINSZ`). The windows-testing.md Option A path: port
`tty_expect.nim` to ConPTY behind `when defined(windows):`, keeping the
`TtySession` record and `expect*` API identical so test bodies need no changes.
The IPC pipes (`THREECODE_TEST_FRAME_FD` etc.) are already pipe-based and
cross-platform. This is the largest single piece (1192-line harness port).

## Current state

Not begun. Investigation complete (this file). Baseline: linux build green,
`test_minline`/`test_history` pass on linux. The `timing` branch is clean
ahead of `eec8d80` except the two untracked plan files.

## Steps

- [ ] 1. **Class A source fix: honor XDG on Windows.** In `src/threecode/util.nim`,
      make `userDataRoot()` and `userConfigRoot()` read `XDG_DATA_HOME` /
      `XDG_CONFIG_HOME` on Windows the same way the POSIX/macOS branch does
      (override when set, else platform default). Verify: `nim c -r` a probe
      that sets the env var and checks the returned path on linux (the Windows
      branch is symmetric, exercised via CI). Then remove `disabled: "win"`
      from `test_session.nim`, `test_update.nim`, `test_util_extra.nim`,
      `test_cli_args.nim`. Fix the `collapseHome` test expectations to be
      separator-agnostic (`~/` + rest joined with `/`). Run all four on linux.

- [ ] 2. **Class B: platform-correct key bytes in the Driver.** In
      `tests/minline_testutils.nim`, replace the hardcoded XMod constants
      (`Left`, `Right`, `Up`, `Down`, `Home`, `End`, `Delete`) with values read
      from `minline.KEYSEQS["left"]` etc. at runtime. `Enter`/`CtrlC`/`Esc`/
      `Backspace`/`AltEnter` stay as-is (platform-independent single bytes from
      ttty). Remove `disabled: "win"` from `test_minline.nim`, `test_history.nim`.
      Verify on linux (behavior unchanged since KEYSEQS == the old constants
      there); Windows correctness follows from KEYSEQS being platform-correct.

- [ ] 3. **Class C: api + stream tests.** Remove `disabled: "win"` from
      `test_api.nim` (pure suites definitely pass; probe tests use execCmdEx
      which works under git-bash — verify or narrowly guard if flaky).
      For `test_streamexec.nim` and `test_netthread_blocks.nim`: attempt a
      `resolveBash()` git-bash fallback so `runStreamingBash` works on CI
      runners; if the netthread test runs clean as-is, enable it. If either
      genuinely cannot run on Windows CI, keep `disabled: "win"` on ONLY that
      file with a precise comment pointing at the concrete blocker (not a
      hand-wavy "flaky").

- [ ] 4. **Class D: ConPTY port of tty_expect.nim.** Port the POSIX PTY
      lifecycle to ConPTY behind `when defined(windows):` — `openpty`→
      `CreatePseudoConsole`, `fork`+`login_tty`+`execv`→
      `InitializeProcThreadAttributeList`+`UpdateProcThreadAttribute`+
      `CreateProcessW`, `waitpid`→`GetExitCodeProcess`, `kill(SIGTERM)`→
      `TerminateProcess`, `TIOCSWINSZ`+`SIGWINCH`→`ResizePseudoConsole`. Keep
      `TtySession` and the `expect*`/`send`/`resize`/`close` API identical.
      Then remove `disabled: "win"` from all 18 tty test files. Verify on linux
      (no regression — the POSIX branch is untouched). Windows correctness
      verified via CI (`windows.yml`). This step is large; may split.

- [ ] 5. **docs + workflow.** Update `docs/windows-testing.md` to reflect the
      new state (XDG honored, Driver KEYSEQS, ConPTY port). If the ConPTY port
      needs the windows.yml run to use categories-sequential like osx.yml did,
      adjust it. Final: `grep -rn 'disabled: "win"' tests/` returns only files
      with a concrete, documented, irreducible blocker.

## Notes

- Verification gate is CI (windows.yml) for Windows-correctness, same model as
  the OSX work used osx.yml. Linux correctness verified locally each step.
- The XDG-on-Windows source change mirrors the macOS XDG change (b7ea0f0) in
  both shape and rationale — it's the established pattern in this codebase.
- `minline.KEYSEQS` is `{.threadvar.}` and populated at module init AND in
  `initKeyTables()`; the Driver reads it after the editor module is imported,
  so it's populated. Reading at `push` time (runtime) not const-eval time.
- Commit per step. Short one-line messages. Do NOT push or merge to main
  (release-level action per ~/p/3CODE.md).
