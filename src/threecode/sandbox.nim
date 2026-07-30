## Filesystem sandbox: policy loading, mtime reload, `3code box` driver.
##
## The policy file format, parser, and rule model live in sandwall
## (`sandwall/rules`); this module is the 3code-specific wrapper: which
## file is the policy source, when to reload it, and whether the OS
## backend actually works on this host.
##
## Each line of `.3code/sandbox` is an access code (`+` writable,
## `-` deny, `*` read-only) plus a target: an absolute path, `~/` home
## path, `./` project-relative path (bare `+` = the project dir), or a
## host/IP with optional `:port`. Host rules fence bash network egress
## through the per-run wall proxy (see the wall-proxy section below).
## See sandwall's rules module for the full grammar.
##
## The policy has exactly one source of truth: the repo file
## `.3code/sandbox`. It is always materialized at launch (see
## `ensureDefaultSandbox`): when absent, it is created from
## `~/.3code/sandbox`, which in turn is created from the built-in
## default text when absent. `~/.3code/sandbox` is only ever a
## template for new project files; it is never loaded directly.
## An implicit read-only rule for the policy file itself is appended
## after every file rule at load time, so no rule in the file (or
## appended by the model via `:sandbox allow`) can weaken it.
##
## `reloadIfChanged` re-reads the file when its mtime changed since
## the last load; it runs before every restricted operation
## (in-process read/write/patch checks and bash launches). The bash
## subprocess additionally loads the policy file itself
## (`3code box --policy`), so a launch always enforces the freshest
## file contents even between parent reloads.

import std/[os, osproc, strutils, times]
from std/posix import kill, Pid
import sandwall
when defined(posix):
  import sandwall/wall as sandwallWall
import types

export sandwall.AccessKind, sandwall.Policy, sandwall.Rule,
       sandwall.RuleKind, sandwall.parsePolicy, sandwall.defaultPolicyText,
       sandwall.repoPolicyPath, sandwall.checkPath,
       sandwall.renderPolicy, sandwall.PolicyDir, sandwall.resolve,
       sandwall.Resolved

var
  current*: Policy
    ## The effective policy. When `active` is false, this is empty
    ## and every check allows.
  active*: bool = false
    ## False means no policy was loaded and bash runs unrestricted.
  procboxExe*: string = ""
    ## Path to the binary to exec for `box restrict` (this one).
  lastMtime: Time

proc guardRuleText(projectDir: string): string =
  ## The implicit rule appended after every file rule so the policy
  ## file itself can never be weakened by a rule in the file (or by
  ## the model via `:sandbox allow`). Last matching rule wins, so this
  ## must be last. The file stays readable: a read-only rule still
  ## allows read.
  "* " & repoPolicyPath(projectDir) & "\n"

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
    ## The effective policy text the proxy enforces: the repo policy
    ## file contents plus the implicit guard rule, matching
    ## loadPolicy.
    let repo = repoPolicyPath(projectDir)
    (if fileExists(repo): readFile(repo) else: "") & "\n" &
      guardRuleText(projectDir)

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
    ## Rewrite the proxy's policy file after a policy reload;
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

proc loadPolicy*(projectDir: string): Policy =
  ## Load the single policy source (the repo file) and remember its
  ## mtime for reloadIfChanged. The implicit guard rule is appended
  ## to the text before parsing.
  let repo = repoPolicyPath(projectDir)
  lastMtime = mtimeOf(repo)
  let text = (if fileExists(repo): readFile(repo) else: "") & "\n" &
    guardRuleText(projectDir)
  parsePolicy(text, projectDir)

proc reloadIfChanged*(projectDir: string): bool =
  ## Re-load the policy when the file changed on disk since the last
  ## load. Returns true when a reload happened. Called before every
  ## restricted operation so a mid-session policy edit takes effect
  ## on the next tool call.
  if not active: return false
  let repo = repoPolicyPath(projectDir)
  let now = mtimeOf(repo)
  if now == lastMtime: return false
  current = loadPolicy(projectDir)
  when defined(posix):
    syncWallProxyPolicy(projectDir)
  true

proc policyHint*(): string =
  ## Where the agent can inspect the rules that bound it. Appended to
  ## sandbox denial messages so a blocked tool call points at the
  ## unrendered policy instead of dumping a (possibly long) rule list
  ## into the conversation.
  "policy: " & repoPolicyPath(getCurrentDir())

proc sandboxPathInCwd*(): string =
  ## The repo-level policy file for the current working directory.
  repoPolicyPath(getCurrentDir())

proc policyPath*(): string =
  ## The single policy file for the current working directory, for
  ## display and for passing to `box --policy`.
  repoPolicyPath(getCurrentDir())

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
  ## reloading the file first when it changed on disk. This is the
  ## in-process gate for the read/write/patch tools; it calls the same
  ## sandwall `checkPath` the sandboxed box subprocess enforces at the
  ## kernel level for bash. `needsWrite = false` allows read-only and
  ## writable; `true` requires writable.
  if not active or not sandboxEnabled: return (true, "")
  discard reloadIfChanged(getCurrentDir())
  let resolved = resolveRawPath(path)
  if resolved.len == 0: return (true, "")
  let access = current.checkPath(resolved)
  case access
  of akWritable: (true, "")
  of akReadOnly: (not needsWrite,
    "sandbox: " & resolved & " is read-only (" & policyHint() & ")")
  of akDeny: (false,
    "sandbox: " & resolved & " is denied by the policy (" & policyHint() & ")")

proc userSandboxPath*(): string =
  ## `~/.3code/sandbox`: the template for new project policy files.
  ## Never loaded directly as policy.
  getHomeDir() / PolicyDir / "sandbox"

proc ensureUserSandbox*(): bool =
  ## Create `~/.3code/sandbox` from the built-in default text if it
  ## does not exist. Runs at every 3code launch.
  let path = userSandboxPath()
  if fileExists(path): return true
  try:
    let dir = path.parentDir
    if not dirExists(dir): createDir(dir)
    writeFile(path, defaultPolicyText())
  except CatchableError:
    return false
  fileExists(path)

proc ensureDefaultSandbox*(dir: string): bool =
  ## Create the policy file at `dir/.3code/sandbox` if none exists,
  ## seeding it from `~/.3code/sandbox` (created from the built-in
  ## default first when absent). Runs at every 3code launch so the
  ## repo file is the always-present single policy source, and also
  ## by `appendRule` to seed the repo file on the first explicit
  ## `:sandbox allow|readonly|deny` edit.
  let path = repoPolicyPath(dir)
  if fileExists(path): return true
  if not ensureUserSandbox(): return false
  let sandboxDir = dir / PolicyDir
  try:
    if not dirExists(sandboxDir): createDir(sandboxDir)
    copyFile(userSandboxPath(), path)
  except CatchableError:
    return false
  fileExists(path)

proc renderSandbox*(p: Policy): string =
  renderPolicy(p)

proc appendRule*(sandboxFile, argPath: string; access: AccessKind): bool =
  ## Append a rule to the repo policy file, creating it from the
  ## default first if it does not exist. Used by `:sandbox
  ## allow|deny|readonly`. After appending, reload so the change is live
  ## for the next check.
  if not fileExists(sandboxFile):
    let projectDir = sandboxFile.parentDir.parentDir
    if not ensureDefaultSandbox(projectDir): return false
  result = sandwall.appendRule(sandboxFile, argPath, access)
  if result:
    current = loadPolicy(getCurrentDir())
