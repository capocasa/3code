# Pre-beta audit: findings and fix plan

Scope: sweep `src/` for footguns before the beta release. The tree has many
refactoring passes behind it; this pass is "is anything awful lurking", not a
style review. Each finding below was verified by reading the code (and, where
noted, executing a repro). Findings are ordered by severity.

Note on the audit environment: a `nimble test` run during the audit failed on
`tests/core/test_ticker_cleanup` with "Permission denied" — that was my own
concurrent-test artifact (two suites raced), not a tree bug. Rerun standalone:
passes clean, exit 0.

## What is OK (checked, no action)

- TLS: every client uses `bundledSslContext()` = `CVerifyPeer` + bundled CA.
  No insecure-skip-verify anywhere.
- OAuth: PKCE S256 correct (big-endian digest serialization), loopback bound
  to 127.0.0.1 only, `state` checked in the callback. Token stores chmod 0600.
- `callHook` raw-closure cast in minline.nim: deliberate, documented workaround
  for a Nim 2.2.10 codegen torn-write bug. Fine as is.
- Session/draft persistence: lock files O_EXCL 0600, drafts written
  atomically (temp+rename). Stale-lock detection with pid liveness check.
- Update path: swap is staged+renamed, perms set explicitly, semver gate,
  throttle. `refuseRoot` present. Auto-update defaults off for source builds.
- netthread model (lock + append-only seq, no closures crossing to worker):
  documented ORC constraint, followed.
- Root refusal, Windows bash guard, early-dispatch subcommands: solid.

## Findings

### 1. CRITICAL — in-process sandbox gate misses `..` traversal (`sandbox.nim:397`)

`resolveRawPath` does `absolutePath(q)` with **no** `normalizedPath`. `checkRawPath`
(the only gate for `read`/`write`/`patch`) then runs `isPathUnder(resolved, rule.path)`
on a string that can still contain `/../`. Verified:

    raw:    /home/user/proj/sub/../../../etc/passwd
    isPathUnder(raw, "/home/user/proj") == true   # wrong: normalizes to /home/user/etc/passwd

Meanwhile the OS backends (Landlock/Seatbelt) canonicalize via `normalize()`
(absolute + normalizedPath + symlink resolution), so the box subprocess is safe,
but the **in-process read/write/patch tools** — which per the module header are
supposed to call "the same sandwall checkPath the box subprocess enforces" —
can be fooled by a `..` in the path when the project rule is `allow` (the
default policy!). Example: `write ../../../.ssh/authorized_keys` in a repo with
the default policy passes the in-process check and writes outside the sandbox.

Symlinks are a separate hole in the *same* comparison: rule paths are
normalized-with-symlink-resolution (`normalizePolicyPath`), the checked path is
not (`absolutePath` only). `/tmp` on macOS is the canonical trap.

Also: `util.resolvePath` (used for the actual file I/O) is likewise
un-normalized, so the write happens at the literal `..` path — outside the
project, outside the rule set.

**Fix** (`src/threecode/sandbox.nim`): in `resolveRawPath`, mirror sandwall's
`normalize()` exactly — `absolutePath(q).normalizedPath`, plus
`expandFilename` on the longest existing ancestor when the full path doesn't
exist (so `write` to a not-yet-created file still canonicalizes). This keeps
"in-process check == kernel check" true, which is the module's stated contract.
Add a regression test in `tests/`: policy allows the project dir, tool path
contains `../..` escaping the project → expect deny.

### 2. HIGH — `web_fetch`/`web_search` tools bypass the sandbox network fence entirely (`actions.nim:632`, `web.nim:146`)

`akWebFetch` calls `fetchUrl` directly from the 3code process; nothing consults
`sandbox.current` host rules. The network fence is only applied to **bash**
children via the wall proxy. So a repo policy `deny *` / `allow
api.openai.com` (the documented posture for locked-down agents) is enforced
for `curl` in bash but not for the native `web_fetch` tool: the model can fetch
`http://169.254.169.254/latest/meta-data` or an internal `10.x` service from a
"fenced" session. On Linux the bash child is netns-fenced; the parent process
making the fetch is not.

**Fix** (`src/threecode/actions.nim`, `akWebFetch` branch): before fetching,
when `sandbox.active` and the policy has host rules (`wallProxyNeeded`), check
the URL's host[:port] against `sandbox.current.checkHost` (or the wall
matcher) exactly as the proxy does; deny → return the same "sandbox: host
denied by the policy" error the bash path produces. `web_search` endpoints are
fixed known-good hosts; gate `web_fetch` only (search APIs are the agent's own
configured backends, not model-chosen URLs).

### 3. MEDIUM — `ui.nim:300` `execShellCmd("start " & url)` runs unquoted through cmd.exe

Windows `openBrowserUrl`. The URL comes from OAuth endpoints here (fixed
constants today), but `execShellCmd` on Windows is `cmd /c <string>`; an
unquoted `start <url>` with `&`/`|` in it executes arbitrary commands. Today's
callers are safe-by-constant, but this is a footgun one refactor away from a
real injection (the OAuth `state`-carrying URL is the future risk; also
`start` mangles URLs with `&` even absent malice — the first query param
opens and the rest is interpreted by cmd).

**Fix**: quote properly for cmd.exe (`start "" "url"`), or better, replace all
three platforms with `openDefaultBrowser` via `startProcess`/`ShellExecute`
and no shell at all. Smallest correct change: macOS/Linux already use
`quoteShell`; Windows branch becomes `execShellCmd("start \"\" " &
quoteShell(url))`.

### 4. MEDIUM — `editPolicy` runs `$VISUAL/$EDITOR` unquoted (`sandbox.nim:457`)

`execShellCmd(editor & " " & quoteShell(sandboxFile))`. The *editor* string is
env-controlled (user's own machine, so low severity), but `VISUAL="code -w"`
is a common legitimate value that becomes `code -w <file>` — works by accident
through cmd/sh. The real trap: `quoteShell` is applied to the file but not the
editor, so an editor path with spaces (`/opt/homebrew/bin/Visual Studio Code`)
silently mis-launches. Decide: either honor single-binary semantics and quote
the editor too, or document that a multi-word VISUAL is a feature. Quote the
editor when it has no spaces, and pass a leading-quoted form otherwise.
(Reading the code I'd leave the multi-word feature; the fix is just quoting the
single-token case consistently.)

Actually the correct minimal fix: keep the string-concat semantics (that IS
how EDITOR works in most tools) but route it through `execShellCmd` only after
validating the editor resolves to an existing binary when it is a single token.
Simplest robust option: `startProcess` split on whitespace when single-token;
document multi-word VISUAL as unsupported.

### 5. MEDIUM — `example/webserve.nim` binds 0.0.0.0 (`example/webserve.nim:240`)

`server.serve(port.Port, serve)` — Nim's `serve` defaults `address = ""`
→ `bindAddr` binds `0.0.0.0`. The example README/echo says "localhost". Anyone
running the example on a laptop on café wifi exposes an unauthenticated agent
(prompt endpoint runs arbitrary model-proposed shell commands on the host) to
the LAN. `--port` exists, no `--host`.

**Fix**: `server.serve(port.Port, serve, address = "127.0.0.1")`, plus a
`--host` flag for people who know what they're doing (the flag's help text
should warn). One-line change + doc line.

### 6. LOW-MEDIUM — `sessionPreamble`'s `shellCapture` swallows the exit code and has a `timeout`-dependency trap (`ui.nim:1073`)

`shellCapture` is documented "cmd must be a literal" — true for all five
current callers. But: (a) `discard execShellCmd` means a missing `timeout`
binary (macOS stock! `timeout` is not in macOS base, only coreutils/gtimeout)
turns every capture into "command not found" → empty output → session silently
loses the git context block with zero signal. On stock macOS `sessionPreamble`
has never worked. (b) The POSIX branch runs `timeout ... sh -c "cmd"` through
the user's *login* `sh` with double-quoted interpolation of the literal —
fine for the five literals, one `"` away from a bug.

**Fix**: on macOS use `/usr/bin/timeout` if present else fall back to plain
`sh -c` with a manual deadline via `execCmdEx(..., options)`-style kill, or
simply preflight `command -v timeout` once and skip the wrapper when absent
(the commands are all sub-second; the 3s timeout is belt-and-braces). Cheapest
correct: probe `findExe("timeout")`; empty → run `sh -c` directly.

### 6b. LOW — same capture pattern: `sandbox.nim:324` `backendWorks` Windows probe builds `cmd /c cd /d X && ...`

Quoted via `quoteShell` on both parts; the `&&` is cmd syntax by design.
Reads fine. No action (noting it was checked).

### 7. LOW — `history` file created 0644 (world-readable) with no chmod (`session.nim:1234`, `minline.nim:528`)

Prompt history is written to `$XDG_DATA_HOME/3code/history`. Auth token files
get explicit 0600 comments; the history — which can contain pasted secrets,
API keys, tokens — gets default perms. On a multi-user box that's readable.

**Fix**: after first create, `setFilePermissions(path, {fpUserRead,
fpUserWrite})` (POSIX; Windows ACLs default-restrict already). Same for the
`.3log` session files (`saveSession` plain `writeFile`) — sessions contain the
full transcript including any secret pasted into a prompt. One helper, three
call sites.

### 8. LOW — `loadTokens` silently returns zero on parse failure (`auth_openai.nim:64`, `auth_xai`)

`except CatchableError: discard` → caller sees "logged out" and the refresh
token stays on disk. A corrupt store (partial write) masquerades as logout.
The swallow-scan doc lists this exact class. Given `writeFile` is not atomic
(storeTokens has no temp+rename), a crash mid-write bricks the login.

**Fix**: make `storeTokens` atomic (temp + rename, like `writeDraftAtomic`),
and have `loadTokens` raise-or-report so the wizard says "token store corrupt:
re-login" instead of silently looping. Minimal: atomic write + one
`debugOut`/stderr line on parse failure.

### 9. LOW — known architectural debt, already on the books (no action this pass)

These are in `guidelines-updated.md` / `cybernetic-plan.md` already; fixing
them is a project, not a beta blocker, and touching fatprompt before a release
violates "don't refactor rendering before a ship". Listed so the audit is
honest:

- `fatprompt/runtime.nim` legacy paint helpers (7 procs) still present.
- `ui.nim`/`display.nim` write scrollback directly (76 direct writes).
- Wizard's private terminal posture (modal flag freeze).
- Indentation pyramids in threecode.nim/api.nim per the guidelines doc.

## Fix order (execution plan)

Do 1 first (it's the actual security boundary), then 2, then the rest are
independent one-liners. Tests: box/sandbox suite for 1; add a narrow test for
the `..`-traversal deny and the web_fetch host gate; run full `nimble test`
after each item.

## Verification checklist (per fix)

1. `nim c -r --path:src --path:tests tests/shell/test_sandbox*.nim` (or the
   box suite) green.
2. New traversal test red-before/green-after (TDD per `.agents/development-guide.md`).
3. Full `nimble test` (sequential, no concurrent runs) green.
4. `git diff` read-through; single-line commit per fix.
