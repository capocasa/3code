## Filesystem sandbox: policy loading, mtime reload, `3code box` driver.
##
## The policy file format, parser, and rule model live in sandwall
## (`sandwall/rules`); this module is the 3code-specific wrapper: which
## files form the cascade, when to reload them, and whether the OS
## backend actually works on this host.
##
## Each line of `.3code/sandbox` is an access word (`allow` writable,
## `deny` deny, `readonly` read-only) plus a target: an absolute path, `~/`
## home path, `./` project-relative path (bare `allow` = the project
## dir), or a host/IP with optional `:port`. Host rules fence bash
## network egress through the per-run wall proxy (see the wall-proxy
## section below). See sandwall's rules module for the full grammar.
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
from std/posix import kill, Pid
import sandwall
when defined(posix):
  import sandwall/wall as sandwallWall
import types

export sandwall.AccessKind, sandwall.Policy, sandwall.Rule,
       sandwall.RuleKind, sandwall.parseCascaded, sandwall.defaultPolicyText,
       sandwall.repoPolicyPath, sandwall.cascadedFiles, sandwall.checkPath,
       sandwall.renderPolicy, sandwall.PolicyDir, sandwall.resolve,
       sandwall.Resolved

var
  current*: Policy
    ## The effective cascaded policy. When `active` is false, this is
    ## empty and every check allows.
  active*: bool = false
    ## False means no policy was loaded and bash runs unrestricted.
  procboxExe*: string = ""
    ## Path to the binary to exec for `box restrict` (this one).
  lastMtimes: tuple[system, repo: Time]

# ------------------------------------------------------------- wall proxy
#
# One wall proxy per 3code run, started lazily when the effective
# policy first shows host rules and shared by every fenced bash launch
# (the sandwall accept loop is sequential and fork-safe; per-launch
# proxies are both wasteful and wrong - see sandwall wall/proxy.nim).

when defined(posix):
  var
    wallProxy: sandwallWall.WallProxy
      ## .sock == nil means not running.
    wallProxyDir*: string = ""
      ## Per-run temp dir holding the merged policy file + unix socket.

proc wallProxyNeeded*(pol: Policy): bool =
  ## Fencing is off until the effective policy names its first host.
  pol.resolve().hosts.len > 0

when defined(posix):

  proc wallPolicyText*(projectDir: string): string =
    ## The effective policy text the proxy enforces: the cascade's two
    ## files (or defaults) concatenated, matching loadCascaded.
    let files = cascadedFiles(projectDir)
    let sysText = if fileExists(files.system): readFile(files.system)
                  else: defaultPolicyText()
    let repoText = if fileExists(files.repo): readFile(files.repo)
                   else: defaultPolicyText()
    sysText & "\n" & repoText & "\n"

  proc proxySockPath*(): string =
    ## The proxy's AF_UNIX listener (Linux bridge target); "" on macOS,
    ## where the sandbox reaches host loopback directly.
    when defined(linux):
      if wallProxyDir.len > 0: wallProxyDir / "proxy.sock" else: ""
    else:
      ""

  proc moveWallSock*(dir: string) =
    ## Repoint the unix listener path at `dir` (the bash tmp dir, which
    ## the fenced policy leaves writable). Must run before
    ## ensureWallProxy; the proxy binds lazily there.
    wallProxyDir = dir

  proc ensureWallProxy*(projectDir: string): bool =
    ## Start the per-run proxy when the policy needs it and it is not
    ## running yet. True when fenced bash may launch.
    if not wallProxyNeeded(current): return false
    if wallProxy.port != 0: return true
    if wallProxyDir.len == 0:
      wallProxyDir = getTempDir() / ("3code-wall-" & $getCurrentProcessId())
      createDir(wallProxyDir)
    let polFile = wallProxyDir / "policy"
    writeFile(polFile, wallPolicyText(projectDir))
    try:
      wallProxy = sandwallWall.startWallProxy(polFile, projectDir,
        port = 0, unixSockPath = proxySockPath())
    except CatchableError as e:
      raise newException(IOError, "wall proxy: " & e.msg)
    true

  proc wallProxyPort*(): uint16 =
    ## The proxy's loopback port; 0 when not running.
    wallProxy.port

  proc syncWallProxyPolicy*(projectDir: string) =
    ## Rewrite the proxy's merged policy file after a cascade reload;
    ## the proxy hot-reloads on mtime.
    if wallProxy.port == 0 or wallProxyDir.len == 0: return
    writeFile(wallProxyDir / "policy", wallPolicyText(projectDir))

  proc stopWall*() =
    ## Proxy + temp dir teardown, called from 3code's cleanup exit proc.
    if wallProxy.port != 0:
      sandwallWall.stopWallProxy(wallProxy)
      wallProxy.port = 0
    if wallProxyDir.len > 0:
      try: removeDir(wallProxyDir)
      except CatchableError: discard
      wallProxyDir = ""

  proc wallEnv*(selfExe, port, sockPath: string;
                existingGitSsh: string): seq[(string, string)] =
    ## Environment additions for a fenced bash launch: the WALL_* vars
    ## box reads, the standard proxy vars pointing at the loopback
    ## proxy (socks5h = remote DNS), and a ProxyCommand GIT_SSH_COMMAND
    ## unless the user already set one. Pure helper; streamexec merges
    ## the result into the child's env table.
    result.add ("WALL_PROXY_PORT", port)
    if sockPath.len > 0:
      result.add ("WALL_PROXY_SOCK", sockPath)
    let hp = "http://127.0.0.1:" & port
    let sp = "socks5h://127.0.0.1:" & port
    result.add ("http_proxy", hp)
    result.add ("https_proxy", hp)
    result.add ("HTTP_PROXY", hp)
    result.add ("HTTPS_PROXY", hp)
    result.add ("ALL_PROXY", sp)
    result.add ("all_proxy", sp)
    result.add ("NO_PROXY", "127.0.0.1,localhost")
    result.add ("no_proxy", "127.0.0.1,localhost")
    if existingGitSsh.len == 0:
      result.add ("GIT_SSH_COMMAND",
        "ssh -o ProxyCommand=\"" & selfExe & " wall connect %h %p\"")

  proc sweepStaleWallDirs*() =
    ## Best-effort removal of proxy dirs from dead 3code processes,
    ## mirroring cleanupStaleBinaries. Runs at startup.
    let tmp = getTempDir()
    for kind, path in walkDir(tmp):
      if kind != pcDir: continue
      let name = path.lastPathPart
      if not name.startsWith("3code-wall-"): continue
      let pid = try: parseInt(name["3code-wall-".len .. ^1])
                except ValueError: continue
      if pid == getCurrentProcessId(): continue
      # A live pid means a live owner; check via kill(pid, 0).
      when defined(posix):
        if posix.kill(pid.Pid, 0) == 0: continue
      try: removeDir(path)
      except CatchableError: discard

proc findProcbox*(): string =
  ## The sandwall CLI is built into 3code as the `box` subcommand, so the
  ## "sandbox binary" the bash tool re-execs is just this process. Return
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
  sandwall.loadCascaded(projectDir)

proc reloadIfChanged*(projectDir: string): bool =
  ## Re-load the cascade when either policy file changed on disk since
  ## the last load. Returns true when a reload happened. Called before
  ## every restricted operation so a mid-session policy edit takes effect
  ## on the next tool call.
  if not active: return false
  let files = cascadedFiles(projectDir)
  let now = (mtimeOf(files.system), mtimeOf(files.repo))
  if now == lastMtimes: return false
  current = sandwall.loadCascaded(projectDir)
  lastMtimes = now
  when defined(posix):
    syncWallProxyPolicy(projectDir)
  true

proc policyHint*(): string =
  ## Where the agent can inspect the rules that bound it. Appended to
  ## sandbox denial messages so a blocked tool call points at the
  ## unrendered policy instead of dumping a (possibly long) rule list
  ## into the conversation.
  let paths = cascadedFiles(getCurrentDir())
  "policy: " & paths.repo & " (project), " & paths.system & " (system)"

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

proc gatherMode*(dir: string): bool
proc gatherRecord(path: string)

proc checkRawPath*(path: string; needsWrite: bool): tuple[allowed: bool, reason: string] =
  ## Check a raw (possibly relative) path against the current policy,
  ## reloading the cascade first when a policy file changed. This is the
  ## in-process gate for the read/write/patch tools; it calls the same
  ## sandwall `checkPath` the sandboxed box subprocess enforces at the
  ## kernel level for bash. `needsWrite = false` allows read-only and
  ## writable; `true` requires writable. In gather mode a denial
  ## appends an `allow` rule to the repo policy and permits instead.
  if not active or not sandboxEnabled: return (true, "")
  discard reloadIfChanged(getCurrentDir())
  let resolved = resolveRawPath(path)
  if resolved.len == 0: return (true, "")
  let access = current.checkPath(resolved)
  case access
  of akWritable: (true, "")
  of akReadOnly:
    if not needsWrite: (true, "")
    elif gatherMode(getCurrentDir()):
      gatherRecord(resolved)
      (true, "")
    else:
      (false, "sandbox: " & resolved & " is read-only (" & policyHint() & ")")
  of akDeny:
    if gatherMode(getCurrentDir()):
      gatherRecord(resolved)
      (true, "")
    else:
      (false, "sandbox: " & resolved & " is denied by the policy (" & policyHint() & ")")

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
  result = sandwall.appendRule(sandboxFile, argPath, access)
  if result:
    current = loadCascaded(getCurrentDir())

proc gatherFlagPath*(dir: string): string =
  ## The gather-mode toggle file. It lives in the policy dir but is not
  ## a policy file: the box subprocess checks for its existence before
  ## every bash launch, so `sandbox gather off` inside a sandboxed
  ## command works even on Landlock (existence checks are unrestricted).
  dir / PolicyDir / "gather"

proc gatherMode*(dir: string): bool =
  ## True while gather mode is on: would-be denials are allowed and
  ## recorded as `allow` rules in the repo policy file instead.
  fileExists(gatherFlagPath(dir))

proc setGatherMode*(dir: string; on: bool) =
  ## Toggle gather mode by creating/removing the flag file.
  let flag = gatherFlagPath(dir)
  if on:
    let sandboxDir = dir / PolicyDir
    if not dirExists(sandboxDir): createDir(sandboxDir)
    writeFile(flag, "")
  else:
    removeFile(flag)

proc gatherRecord(path: string) =
  ## Live-append an `allow` rule for a path gather mode just permitted.
  ## Failures are silent: gather mode never breaks a tool call.
  if not ensureDefaultSandbox(getCurrentDir()): return
  discard sandwall.appendRule(sandboxPathInCwd(), path, akWritable)

proc gatherRecordBash*(dir: string) =
  ## Bash runs unconfined in gather mode; record the directory the
  ## command runs in so an out-of-project bash cwd still gets a rule.
  ## Inside the project this is a no-op rule (already allowed).
  gatherRecord(dir)
