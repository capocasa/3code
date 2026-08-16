# Refactor backlog: pre-beta audit findings

Working record of the pre-beta audit (2026-04). Full analysis and repro notes
live in `plan-audit-beta.md`; this file is the tracker the worktrees work from.

Owner assignments below; when an item is done its worktree branch is merged
into `refactor` and the line gets a `[merged]` marker with the commit.

## Owner: `audit-sec` (worktree ../audit-sec) — the sandbox boundary

- [x] 1. **CRITICAL** `..` traversal defeats the in-process sandbox gate.
  `sandbox.nim:397` `resolveRawPath` does `absolutePath` with no
  `normalizedPath` + symlink resolution, so `write ../..` escapes the project
  rule while the OS backend (sandwall `normalize()`) would block it. Mirror
  sandwall's `normalize()` semantics (absolute + normalizedPath +
  expandFilename on longest existing ancestor for not-yet-existing targets).
  Regression test: policy allows project dir, tool path escapes via `..` and
  via a symlinked dir → both must deny.
- [x] 2. **HIGH** `web_fetch` bypasses the network fence (`actions.nim:632`).
  Host rules fence bash children via the wall proxy; the native tool fetches
  from the parent with no check. When `sandbox.active` and
  `wallProxyNeeded`, gate the URL's host[:port] against the wall matcher;
  deny → same "sandbox: host denied" error as the bash path. Gate
  `web_fetch` only (search endpoints are fixed configured hosts). Test both
  directions.

## Owner: `audit-win` (worktree ../audit-win) — Windows + shell quoting

- [x] 3. **MEDIUM** `ui.nim:300` `openBrowserUrl` Windows branch runs
  `execShellCmd("start " & url)` unquoted through cmd.exe. Fix to
  `start "" <quoted url>` (the empty title arg keeps `start` from treating a
  quoted URL as a window title). macOS/Linux already quote; align.
- [x] 4. **MEDIUM** `sandbox.nim:457` `editPolicy` concatenates `$VISUAL` /
  `$EDITOR` unquoted. Single-token editor paths with spaces misfire;
  multi-word EDITOR values (`code -w`) currently work by accident. Keep
  shell-string semantics (that's how EDITOR works everywhere) but document
  it and quote the file argument consistently (already done); no behavior
  change required beyond a comment — verify the Windows `notepad` default
  path still resolves. Lowest-risk option preferred: no refactor.

## Owner: `audit-web` (worktree ../audit-web) — example + local-net exposure

- [x] 5. **MEDIUM** `example/webserve.nim:240` binds 0.0.0.0 (Nim `serve`
  default) while its docs say localhost. Bind `127.0.0.1` by default, add
  `--host` opt-in flag with a help-line warning. Update the header comment.
- [x] 6. **LOW** `ui.nim:1073` `shellCapture` depends on the `timeout`
  binary, absent on stock macOS → `sessionPreamble` silently loses the whole
  git-context block there. Preflight `findExe("timeout")` once; when absent
  run the command directly (all five callers are sub-second literals). Keep
  the existing Windows shape.

## Owner: `audit-perm` (worktree ../audit-perm) — file permissions + token store

- [x] 7. **LOW** `history` (`session.nim:1234` first-create, and minline
  `historyInit` creates an empty file) and `.3log` session files
  (`session.nim:846` plain `writeFile`) are written with default perms
  (0644). They can hold pasted secrets. Apply 0600 on create (POSIX;
  `setFilePermissions` is a no-op-ish on Windows defaults). One helper,
  minimal call sites: history file create + saveSession write.
- [x] 8. **LOW** Token store (`auth_openai.nim`, `auth_xai.nim`):
  `storeTokens` plain `writeFile` → crash mid-write bricks the login, and
  `loadTokens` swallows parse errors as "logged out". Make the write atomic
  (temp + rename like `writeDraftAtomic`), and have a corrupt store surface
  a "store corrupt, re-login" error rather than silent logout. Keep both
  providers symmetric.

## Not assigned (deliberate, post-beta)

- Legacy fatprompt paint helpers, direct scrollback writes in ui/display,
  wizard terminal posture, deep-indentation cleanup — all already tracked in
  `guidelines-updated.md` / `cybernetic-plan.md`. Do not refactor terminal
  rendering before a release.

## Rules for all worktrees

- Fix only the listed items. No drive-by refactors.
- TDD per `.agents/development-guide.md`: repro first, then fix.
- Full `nimble test` green before reporting done.
- Single-line commit message per item; commit when the item is complete.

## Outcome (all merged into `refactor`)

- audit-sec → e62b9bc (traversal fix + tests), 35462e6 + a4488b3 (web_fetch
  host gate + tests). Merged 89ffa7b.
- audit-win → 1628666 (start "" quoting), 76e720a (EDITOR contract doc).
  Merged be57812.
- audit-web → 2adb63b (webserve loopback + --host), e9cd797 (shellCapture
  timeout fallback). Merged b84ffde.
- audit-perm → a8a6759 (0600 history/session + tests), d51c9c9 (atomic token
  store + corrupt diagnostic + tests). Merged f9949e6.

Verification: full testament run on the merged tree; the three reported
failures (test_cli_args, test_config_validation, test_wall_bash) reproduce on
a pristine non-audit worktree too — they require a pre-built ./3code binary
at the repo root. With `nim c -o:3code src/threecode.nim` all three pass
exit-0. Not regressions.

Worktrees audit-{sec,win,web,perm} removed after merge.
