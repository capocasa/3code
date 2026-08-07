# Handoff: tc-win.exe segfaults in Windows Terminal (light profile)

## State

- Commit `26d89be` (branch `colormode`) renamed the config setting
  `mode/bright` -> `tone/light` (legacy spellings still accepted) and added
  `detectColorModeWindows()` in `src/threecode/util.nim` so `tone = auto`
  actually queries the background on Windows via OSC 11.
- Build host: Linux, cross-compiled with mingw:
  `nim c --os:windows --cpu:amd64 --gcc.exe:x86_64-w64-mingw32-gcc --gcc.linkerexe:x86_64-w64-mingw32-gcc --hints:off -d:ssl --threads:on --path:src -o:tc-win.exe src/threecode.nim`
  (OpenSSL DLLs + cacert.pem from https://nim-lang.org/download/dlls.zip
  must sit next to the exe.)
- On beck (`C:\Users\Quickemu\`):
  - `tc-win.exe` - the build above. `-v` works. Full startup works over
    ssh (no console) and under the repo's ConPTY harness
    (`test_conpty_diag.exe` test C passed: welcome screen, prompt, no crash).
  - `build\3code_stub.exe`, `test_conpty_diag.exe` - test binaries.
- **Bug**: `tc-win.exe` segfaults when launched directly in a real Windows
  Terminal window (light profile). The only code path that differs from the
  passing ConPTY run is that Windows Terminal *answers* the OSC 11 query, so
  the reply-read branch of `detectColorModeWindows()` runs for real.
  A segfault was also reported for an earlier build, so the crash may
  predate this change (the old code never ran the query on Windows).

## Suspects, ranked

1. `cast[string](buf.toOpenArray(0, total - 1))` with `total = 0` - WT
   answers OSC 11, but if the first ReadFile returns 0 bytes this slices
   `0..-1` and cast-to-string may trip on it. Guard `total == 0`.
2. `buf.toOpenArray` on a stack array cast to string is fine in principle,
   but check `'\x07' in buf.toOpenArray(...)` when `total = 0` (same edge).
3. `getConsoleMode`/`setConsoleMode` decl mismatch (int32 vs DWORD ptr) -
   worked over ConPTY though.
4. The segfault is elsewhere entirely (pre-existing, e.g. the recent TLS
   fix a9ed256) and detection is a red herring. Verify by running a build
   with `tone = dark` pinned in the config: if it still crashes, detection
   is not the culprit.

## Next steps

1. Reproduce with a stack trace: build with `-d:debug --stackTrace:on
   --lineTrace:on` (mingw gdb backtrace via `gdb tc-win.exe` on beck if
   available, or Windows `procdump`). The exception code 0xC0000005 vs
   0xC0000142 distinguishes segfault from DLL init failure.
2. Test `tone = dark` in `%APPDATA%\3code\config` to isolate detection.
3. Fix the empty-read edge (guards around `total`) regardless - it's a
   real latent bug.
4. Re-verify: `nimble test` on Linux, cross-build, rerun
   `test_conpty_diag.exe` on beck, then hand the exe back for a WT light
   profile run.

## Env notes

- beck: Windows 10.0.26200, ssh via `ssh beck`, home `C:\Users\Quickemu`.
- The user runs the binary in Windows Terminal with a light color profile.
- `WT_SESSION` env var is set in real WT (absent in the ConPTY harness
  unless passed through) - can be used to confirm the environment differs.
