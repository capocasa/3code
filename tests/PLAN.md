# Test plan: integration coverage we want, one-at-a-time

Each section below is a self-contained task ready to paste into an
implementor. We work them one at a time, in order. Mark a task done by
deleting its section after merge.

## What's already covered (don't duplicate)

- `tests/test_update.nim` — unit tests for `semverGt` / `parseSemver`
  and the `auto_update` config gate. Pure logic, no network.
- `tests/test_render.nim` — markdown render parity (live vs replay) and
  ANSI/structural smoke checks.
- `tests/test_golden.nim` + `tests/golden/*.gold` — byte-exact freeze of
  `renderAssistantContent`, `renderTokenLine`, `renderToolBanner`,
  `renderToolPending`. Fail on any drift; regen with
  `THREECODE_GOLDEN_UPDATE=1 nimble test`.
- `tests/test_replay.nim`, `tests/test_parser.nim`, `tests/test_web.nim`
  — domain unit tests.

The gap is integration coverage: install script and auto-update both
exercise paths only real binaries on real CI runners hit. We bridge
that here.

## Task 1: install-script smoke on every push

### Goal

Verify that `https://3code.capocasa.dev/install` actually installs a
working binary on each supported platform. Catches breakage in the
script (wrong asset name, broken extraction, missing PATH update,
regression in `install.ps1`) before users see it.

### Scope

- Trigger: every push and every PR. Not tag-gated, not gated on
  release. Install-script breakage is independent of release cadence.
- Platforms: `ubuntu-22.04`, `macos-latest`, `windows-latest`. Same
  matrix as the build job.
- Runs in parallel with the existing `build` job. Independent.

### Implementation sketch

Add a new job `e2e-install` to `.github/workflows/release.yml`, in
parallel with `build`. Per platform:

```yaml
e2e-install:
  strategy:
    fail-fast: false
    matrix:
      os: [ubuntu-22.04, macos-latest, windows-latest]
  runs-on: ${{ matrix.os }}
  steps:
    - name: Install (Unix)
      if: runner.os != 'Windows'
      run: curl -sSL https://3code.capocasa.dev/install | bash
    - name: Install (Windows)
      if: runner.os == 'Windows'
      shell: pwsh
      run: iwr -useb https://3code.capocasa.dev/install.ps1 | iex
    - name: Smoke
      run: 3code --version
```

The `3code --version` line exits 0 and prints the version on success,
non-zero on any failure. That's a sufficient smoke. If `3code` isn't
on PATH after install, the step fails — and that's exactly the bug we
want surfaced.

### Gotchas

- **PATH propagation across steps.** `install.sh` may put the binary
  in `~/.local/bin` or `/usr/local/bin`, which may not be on the
  runner's PATH for subsequent steps. Add `export PATH=...` in the
  Install step or use `$GITHUB_PATH` to persist.
- **Windows shell.** `install.ps1` needs PowerShell. Use
  `shell: pwsh`. Don't try to run it under bash.
- **Hosted-script availability.** `3code.capocasa.dev` is a
  third-party host (Cloudflare/Pages/whatever you have it on). A
  flaky hosting day will fail CI for non-bug reasons. Acceptable for
  now; revisit if it becomes noisy.
- **No tag gate.** This runs on every push, including PRs from
  forks. That's fine — the install script is public anyway.
- **Don't gate the build on this.** `e2e-install` is a parallel job,
  not a `needs:` predecessor of `build` or `release`. Install-script
  failure should be visible but not block a fix that's already in the
  current PR.

### Success criterion

A push to a branch that breaks the install script (e.g., changes to
the install script itself, or a release that publishes the wrong
asset name) makes `e2e-install` red on at least one platform. A push
that doesn't touch install paths leaves it green.

---

## Task 2: auto-update smoke after tag publish

### Goal

After a tag is pushed and the release is published, verify that an
**older** installed binary actually picks up the new version via the
auto-update path. Peace-of-mind smoke; not a release gate.

The release is already public by the time this runs. If the test
fails, we know we shipped a broken update. We fix forward.

### Scope

- Trigger: tag push only (`if: startsWith(github.ref, 'refs/tags/')`).
- Platforms: `ubuntu-22.04`, `macos-latest`. **Skip Windows** — the
  current `update.nim` has `proc spawnBackgroundUpdateMaybe*() =
  discard` for non-POSIX, so there's nothing to test.
- Runs after `release: needs: build`. Add `e2e-update: needs:
  release`.
- This job is **non-blocking by design**: the user is fine with the
  release going out and this failing as a notification. Don't add a
  retroactive "delete the release" step.

### Implementation sketch

```yaml
e2e-update:
  needs: release
  if: startsWith(github.ref, 'refs/tags/')
  strategy:
    fail-fast: false
    matrix:
      os: [ubuntu-22.04, macos-latest]
  runs-on: ${{ matrix.os }}
  steps:
    - name: Install older binary via official script
      run: curl -sSL https://3code.capocasa.dev/install | bash
    - name: Confirm older version is older
      run: |
        v=$(3code --version)
        if [ "$v" = "${{ github.ref_name }}" ]; then
          echo "installed binary is already the new tag; cannot test update"
          exit 1
        fi
        echo "installed: $v, target: ${{ github.ref_name }}"
    - name: Trigger update foreground
      run: |
        rm -f ~/.config/3code/last-update-check
        3code --self-update-check
    - name: Verify update landed
      run: |
        v=$(3code --version)
        if [ "$v" != "${{ github.ref_name }}" ]; then
          echo "update did not land: still $v, expected ${{ github.ref_name }}"
          exit 1
        fi
        echo "update verified: $v"
```

We use `--self-update-check` (foreground, synchronous) rather than
relying on the daemon path. The daemon's correctness is a separate
concern; here we test the **update logic** (fetch, download, extract,
swap) on a real release artifact. Macos-side daemonization was
already manually verified.

### Gotchas

- **Throttle marker.** The install script's first `3code` invocation
  (in step 2) sets `~/.config/3code/last-update-check`. Before
  triggering the update, `rm -f` it.
- **False-pass when versions match.** Step 2 ("Confirm older version
  is older") explicitly fails if the installed binary already
  matches the tag. Without this, a re-tag or manual workflow run
  would trivially pass without testing anything.
- **Path-of-binary on swap.** `swapBinary` rewrites the path returned
  by `getAppFilename()`. On the runner, this is wherever the install
  script put the binary (likely `~/.local/bin/3code` or
  `/usr/local/bin/3code`). The swap requires write access to that
  directory. The install script should already have ensured writable
  perms, but if `e2e-update` fails with permission errors, that's a
  bug in the install script, not the updater.
- **Release-publish race.** `needs: release` only guarantees the
  release **job** finished, not that the GitHub-side release object
  is queryable from `api.github.com/repos/.../releases/latest`. There
  may be a brief replication lag. If `--self-update-check` returns
  cleanly but the version doesn't flip, retry once with a 30s sleep
  before declaring failure.
- **macOS Gatekeeper.** The swapped-in binary is freshly downloaded
  and may have a quarantine xattr. On the CI macOS runner this is
  usually fine because runners disable Gatekeeper, but if you see
  `Killed: 9` after the swap, the binary's signature/quarantine is
  the cause. Mitigation belongs in the build job (ad-hoc sign after
  `lipo`) rather than the test.
- **Don't make this `needs` of a downstream job.** This is a leaf
  smoke. If it fails, we get a red X on the workflow, GitHub emails
  on failure, done. No cascade.

### Success criterion

After a tag push and successful release, the job goes green within
~3 minutes per platform. If the auto-update path breaks (network
asset misnamed, swap fails, version-flip doesn't happen), we get a
red leaf and an email — peace of mind without blocking the release.

---

## Task 3: streaming-render end-to-end smoke

### Goal

Catch the class of bug that hit on 0.2.6: binary launches fine,
process completes fine, but **content doesn't render** on a real
terminal. Unit tests can't catch this; the render helpers in
`test_golden.nim` freeze the **output procs**, but the **streaming
path** (curl subprocess, SSE chunk loop, spinner thread, bullet +
content + bar lifecycle) is untested.

### Scope

- Trigger: every push.
- Platforms: at least `ubuntu-22.04` and `macos-latest`. Windows
  optional (statusbar-mode never enabled there, but inline path
  still applies).
- New test file `tests/test_e2e_stream.nim` driving a stub SSE
  server; binary launched in a pty so `isatty(stdout)` is true and
  the live render path actually runs.

### Implementation sketch

Two pieces:

1. **Stub SSE server in Nim** — a tiny in-process HTTP server that
   serves `/chat/completions` with a canned SSE stream. Bind to
   `127.0.0.1:0` (let the OS pick a port), pass the URL to 3code via
   a one-shot config or `--url` flag.

2. **Pty harness** — Nim has no stdlib pty; shell out to `script` on
   macOS / Linux: `script -q /dev/null ./3code -m stub.test "say hi"`
   captures stdout while presenting a pty. Capture bytes, assert:
   - `●` (the bullet) appears
   - the canned reply text appears
   - a dim token-receipt line (`○` + `↑↻↓` glyphs) appears
   - the order is bullet → content → receipt

### Gotchas

- **Time and width determinism.** The spinner uses `epochTime`
  and the token bar embeds elapsed seconds. Assert with regex
  (`\d+s`) not exact match. `terminalWidth` from inside `script` is
  whatever the host shell reports; pin via `stty cols 80` before
  launch.
- **Spinner thread and stdout interleaving.** Captured stream may
  contain partial frames before the bullet (e.g., `\r⠋  ↑0...`).
  Strip CR-prefixed runs before asserting on content; or use a
  cleanroom assertion that just checks the final state has the
  expected glyphs.
- **No real provider key.** The stub responds to whatever auth header
  3code sends. Use a placeholder API key in the test config.
- **One job, not three.** Don't blow up the matrix again — this test
  is a single Nim binary that runs `nimble test` like the others.
  The pty machinery is internal to the test.
- **Windows ptys are different.** `script` doesn't exist on Windows.
  If you skip Windows here, document why (`when not defined(windows):`
  guard at top of `test_e2e_stream.nim`).

### Success criterion

A change to the streaming path that breaks rendering on Linux or
macOS (e.g., re-introducing the 0.2.6 statusbar) makes
`test_e2e_stream` red. Today's code, replayed against the stub,
emits a clean bullet+content+receipt sequence and passes.

---

## When tasks are done

Delete the corresponding section. The file should never grow
indefinitely; it's a working queue, not a log. Commit history is the
log.
