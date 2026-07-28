## Filesystem sandbox: policy loading, mtime reload, `3code box` driver.
##
## The policy file format, parser, and rule model live in procbox
## (`procbox/rules`); this module is the 3code-specific wrapper: which
## files form the cascade, when to reload them, and whether the OS
## backend actually works on this host.
##
## Each line of `.3code/sandbox` is an access code (`+` writable,
## `-` deny, `*` read-only) plus a target: an absolute path, `~/` home
## path, `./` project-relative path (bare `+` = the project dir), or a
## host/IP with optional `:port`. Host rules are parsed for the future
## network milestone but not enforced yet. See procbox's rules module
## for the full grammar.
##
## The effective policy is the cascade of the system file
## (`~/.config/3code/sandbox`) and the repo file (`.3code/sandbox`),
## default text when absent, so the sandbox is always on.
##
## `reloadIfChanged` re-reads the cascade when either file's mtime
## changed since the last load; it runs before every restricted
## operation (in-process read/write/patch checks and bash launches).
## The bash subprocess additionally loads the policy files itself
## (`3code box --policy`), so a launch always enforces the freshest
## file contents even between parent reloads.

import std/[os, osproc, strutils, times]
import procbox
import types

export procbox.AccessKind, procbox.Policy, procbox.Rule,
       procbox.RuleKind, procbox.parseCascaded, procbox.defaultPolicyText,
       procbox.repoPolicyPath, procbox.cascadedFiles, procbox.checkPath,
       procbox.renderPolicy, procbox.PolicyDir

var
  current*: Policy
    ## The effective cascaded policy. When `active` is false, this is
    ## empty and every check allows.
  active*: bool = false
    ## False means no policy was loaded and bash runs unrestricted.
  procboxExe*: string = ""
    ## Path to the binary to exec for `box restrict` (this one).
  lastMtimes: tuple[system, repo: Time]

proc findProcbox*(): string =
  ## The procbox CLI is built into 3code as the `box` subcommand, so the
  ## "procbox binary" the bash tool re-execs is just this process. Return
  ## its own path; empty only if it can't be resolved (shouldn't happen).
  try:
    result = getAppFilename()
  except CatchableError:
    result = ""

proc backendWorks*(exe: string): bool =
  ## Probe whether the OS-native sandbox backend (Landlock/Seatbelt/ACL)
  ## can actually restrict on this host. Re-execs this binary as
  ## `box restrict <tmpdir> -- true`; success means the kernel applies the
  ## domain. Fails on kernels built without Landlock, runners under a
  ## seccomp filter that blocks the syscall, etc. Callers clear `procboxExe`
  ## when this returns false so the bash tool falls back to the unconfined
  ## setsid path rather than failing every bash command.
  if exe.len == 0: return false
  let tmp = getTempDir() / ("3code-probe-" & $getCurrentProcessId())
  try:
    if not dirExists(tmp): createDir(tmp)
    # Capture (discard) stdout+stderr so a failing backend's OSError
    # traceback never leaks into the parent's output, which would trip
    # tests that assert no "unhandled exception" appears.
    let (outp, code) = execCmdEx(
      quoteShell(exe) & " box restrict " & quoteShell(tmp) &
        " -- true </dev/null >/dev/null 2>&1")
    discard outp
    result = code == 0
  except CatchableError:
    result = false

proc mtimeOf(path: string): Time =
  try: getLastModificationTime(path)
  except OSError: fromUnix(0)

proc loadCascaded*(projectDir: string): Policy =
  ## Load the cascade and remember the file mtimes for reloadIfChanged.
  let files = cascadedFiles(projectDir)
  lastMtimes = (mtimeOf(files.system), mtimeOf(files.repo))
  procbox.loadCascaded(projectDir)

proc reloadIfChanged*(projectDir: string): bool =
  ## Re-load the cascade when either policy file changed on disk since
  ## the last load. Returns true when a reload happened. Called before
  ## every restricted operation so a mid-session policy edit takes effect
  ## on the next tool call.
  if not active: return false
  let files = cascadedFiles(projectDir)
  let now = (mtimeOf(files.system), mtimeOf(files.repo))
  if now == lastMtimes: return false
  current = procbox.loadCascaded(projectDir)
  lastMtimes = now
  true

proc sandboxPromptSection*(): string =
  ## A compact agent-facing summary of the sandbox boundaries, spliced
  ## into the system prompt via the {{sandbox}} placeholder. Empty when
  ## the sandbox is off, so prompts stay byte-identical to before.
  ## Reloads on policy mtime change so a mid-session edit reaches the
  ## model on the next turn.
  if not active or not sandboxEnabled: return ""
  discard reloadIfChanged(getCurrentDir())
  let paths = cascadedFiles(getCurrentDir())
  var body = renderPolicy(current).strip
  const maxLines = 40
  var lines = body.splitLines
  if lines.len > maxLines:
    body = lines[0 ..< maxLines].join("\n") &
      "\n... (" & $(lines.len - maxLines) & " more rules in the policy file)"
  "\n\n# Sandbox\n\n" &
    "Your bash commands run kernel-confined (Landlock/Seatbelt/ACL) and " &
    "your file tools are checked against the same policy. Effective rules " &
    "(last match wins; anything unmentioned is denied):\n\n" & body & "\n\n" &
    "Policy files: " & paths.repo & " (project), " & paths.system &
    " (system). Propose changes to the user; never try to edit or bypass " &
    "them. Denied operations fail with EACCES or a sandbox error."

proc sandboxPathInCwd*(): string =
  ## The repo-level policy file for the current working directory.
  repoPolicyPath(getCurrentDir())

proc policyPaths*(): tuple[system, repo: string] =
  ## The cascade files for the current working directory, for display
  ## and for passing to `box --policy`.
  cascadedFiles(getCurrentDir())

proc resolveRawPath(p: string): string =
  ## Absolute cleaned form of `p`, ~-expanded. Mirrors util.resolvePath
  ## without pulling util (which would create a cycle via types). Empty
  ## for an empty input.
  if p.len == 0: return ""
  var q = p
  if q.startsWith("~"): q = expandTilde(q)
  try: absolutePath(q) except CatchableError: q

proc checkRawPath*(path: string; needsWrite: bool): tuple[allowed: bool, reason: string] =
  ## Check a raw (possibly relative) path against the current policy,
  ## reloading the cascade first when a policy file changed. This is the
  ## in-process gate for the read/write/patch tools; it calls the same
  ## procbox `checkPath` the sandboxed box subprocess enforces at the
  ## kernel level for bash. `needsWrite = false` allows read-only and
  ## writable; `true` requires writable.
  if not active or not sandboxEnabled: return (true, "")
  discard reloadIfChanged(getCurrentDir())
  let resolved = resolveRawPath(path)
  if resolved.len == 0: return (true, "")
  let access = current.checkPath(resolved)
  case access
  of akWritable: (true, "")
  of akReadOnly: (not needsWrite, "sandbox: " & resolved & " is read-only")
  of akDeny: (false, "sandbox: " & resolved & " is outside the allowed paths")

proc ensureDefaultSandbox*(dir: string): bool =
  ## Create the default policy file at `dir/.3code/sandbox` if none
  ## exists, seeding it with the built-in default policy. Used only by
  ## `appendRule` to seed the repo file on the first explicit
  ## `:sandbox allow|readonly|deny` edit. Not part of startup: the
  ## cascade loads the default in-memory when no file is present.
  let path = repoPolicyPath(dir)
  if fileExists(path): return true
  let sandboxDir = dir / PolicyDir
  try:
    if not dirExists(sandboxDir): createDir(sandboxDir)
    writeFile(path, defaultPolicyText())
  except CatchableError:
    return false
  fileExists(path)

proc renderSandbox*(p: Policy): string =
  renderPolicy(p)

proc appendRule*(sandboxFile, argPath: string; access: AccessKind): bool =
  ## Append a rule to the repo policy file, creating it with the default
  ## contents first if it does not exist. Used by `:sandbox
  ## allow|deny|readonly`. After appending, reload so the change is live
  ## for the next check.
  if not fileExists(sandboxFile):
    let projectDir = sandboxFile.parentDir.parentDir
    if not ensureDefaultSandbox(projectDir): return false
  result = procbox.appendRule(sandboxFile, argPath, access)
  if result:
    current = loadCascaded(getCurrentDir())
