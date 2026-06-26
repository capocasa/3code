# OSX Testing

macOS can't be exercised on the Linux dev box: the dev box has no Nim toolchain
for cross-compiling a working macOS binary, and stock macOS lacks the GNU
coreutils that Linux takes for granted. Two whole classes of bug slip through
Linux-only testing:

1. **Missing external binaries.** Stock macOS ships no `timeout`, no `diff`, and
   LibreSSL instead of OpenSSL at `/usr/lib/libssl.dylib`. Any code path that
   shells out to a GNU coreutils binary, or dlopens OpenSSL by a hardcoded name,
   fails on macOS with `exec: <cmd>: not found` or a TLS handshake error. Recent
   fixes removed the `timeout` and `diff` dependencies (native watchdog thread,
   native diff); guard against reintroducing them.

2. **Slow provider heads.** `readResponseHead` uses the same 500ms recv-wake
   timeout as the streaming body loop. Providers that hold the connection for
   several seconds before emitting even the HTTP status line (z.ai GLM, ~7s to
   first byte) must be tolerated by looping on `StreamTimeoutError`, not treated
   as a stale connection.

## The stefani VM

`stefani` is an x86_64 macOS VM for testing. SSH into it over the loopback port:

```sh
ssh stefani
```

It has `curl` but no Nim, no Xcode, no Homebrew — a clean stock macOS. The
3code binary lives at `~/.local/bin/3code`. Run it interactive:

```sh
ssh stefani 3code
```

The `nvidia` provider (configured in `~/.config/3code/config`) is the default
test target. It's a known-good combo, so no `-x` (experimental) flag is needed,
and its endpoint is fast and reliable for exercising the full agent loop
including tool calls.

## Iteration loop: build on OSX, install on stefani

You cannot build a macOS binary on the Linux dev box and run it. Build via CI,
then pull the artifact onto stefani. The **OSX workflow** (`.github/workflows/osx.yml`)
builds only the macOS universal binary and publishes it, finishing in ~5 minutes
versus the full Release workflow (which waits on every matrix leg and can hang
20+ min on the Linux tty test). This is the fast path.

```sh
# 1. Commit your fix to main and push.
git push origin main

# 2. Fire the OSX-only build + publish.
gh workflow run osx.yml --ref main

# 3. Watch it (macOS build ~5 min, then a pages deploy).
gh run watch $(gh run list --branch main --workflow osx.yml --limit 1 \
  --json databaseId --jq '.[0].databaseId')

# 4. On stefani: install the freshly published binary, then exercise it.
ssh stefani 'curl -fsSL https://3code.capocasa.dev/main/install | sh'
ssh stefani 3code
```

The install script copies only the `3code` binary into `~/.local/bin`. The
published tarball also bundles `libssl.3.dylib`, `libcrypto.3.dylib`, and
`cacert.pem` alongside it (the binary sets `DYLD_LIBRARY_PATH` to its own
directory in `main()` so it finds the dylibs). On stefani the system LibreSSL
loads, so the dylibs aren't strictly required there, but on a clean Homebrew-free
install they are.

### Verifying a fix

Don't just check `--version`. Exercise the actual code path that broke. For a
bash tool bug, give the agent a task that requires shell calls and confirm no
`exec: ...: not found` in stderr:

```sh
ssh stefani '3code "list files in the current directory with bash" \
  > /tmp/out.txt 2>/tmp/err.txt & PID=$!; sleep 40; \
  kill -0 $PID 2>/dev/null && { echo HANGING; kill -9 $PID; } || echo COMPLETED; \
  grep -iE "not found|error|timed out" /tmp/err.txt || echo "(stderr clean)"'
```

A completed run with empty stderr is the green light.

## Regression tests that catch OSX bugs on Linux CI

Both OSX failure classes have Linux-runnable regression tests, so CI catches
them before they reach a Mac:

- **Slow head read:** `tests/test_streaming_sse.nim`, suite
  "streaming SSE: slow response head". A local SSE server delays the HTTP
  response head past the recv-wake window. On the pre-fix code this fails with
  `recv timed out`; the fix loops on `StreamTimeoutError`.
- **Native bash timeout:** `tests/test_streamexec.nim`, suite
  "streamexec: no external timeout dependency". Confirms `runAction`/`runStreamingBash`
  execute without shelling out to `timeout`, and that the native watchdog kills
  a runaway command (exit 124) within the time bound.

When fixing an OSX-specific bug, add a regression test here (Linux-runnable) and
verify it fails on the pre-fix code before committing the fix.
