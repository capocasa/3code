## Filesystem sandbox: policy loading, mtime reload, `3code sandbox` driver.
##
## The policy file format, parser, and rule model live in sandwall
## (`sandwall/rules`); this module is the 3code-specific wrapper: which
## file is the policy source, when to reload it, and whether the OS
## backend actually works on this host.
##
## Each line of the policy file is an access word (`allow` writable,
## `deny` deny, `readonly` read-only) plus a target: an absolute path,
## `~/` home path, `./` project-relative path (bare `allow` = the
## project dir), or a host/IP with optional `:port`. Host rules fence
## bash network egress through the per-run wall proxy (see the
## wall-proxy section below). See sandwall's rules module for the full
## grammar.
##
## There is exactly one active policy file, never a cascade: the repo
## file `.sandboxrc` when it exists, else the user file
## `~/.config/3code/sandboxrc` when the user wrote one, else the
## built-in default in memory. 3code never creates the user file, so a
## user who never configured anything always gets the current shipped
## default, not whatever default a long-ago first run froze to disk. A
## `:sandbox allow|readonly|deny` edit materializes the repo file from
## the effective policy text, so project rules start from the user's
## baseline instead of from scratch.
##
## `reloadIfChanged` re-reads the active file when its mtime changed
## since the last load; it runs before every restricted operation
## (in-process read/write/patch checks and bash launches). The bash
## subprocess additionally loads the policy file itself
## (`3code sandbox --policy`), so a launch always enforces the freshest
## file contents even between parent reloads.

import std/[os, osproc, strutils, times]
from std/posix import kill, Pid
import sandwall
when defined(posix):
  import sandwall/wall as sandwallWall
import types
import util

export sandwall.AccessKind, sandwall.Rule,
       sandwall.RuleKind, sandwall.parsePolicy, sandwall.checkPath,
       sandwall.renderPolicy, sandwall.resolve,
       sandwall.Resolved

const
  PolicyFile* = ".sandboxrc"
    ## The repo-level policy file, directly in the project root.
  UserPolicyFile* = "sandboxrc"
    ## The user-level policy file, next to the user config dir.

type Policy* = seq[Rule]
  ## The effective rule set. Sandwall 0.2.4 dropped the wrapper object
  ## in favour of a bare seq[Rule]; 3code keeps the alias so the rest
  ## of the codebase reads `Policy`.

proc defaultPolicyText*(): string =
  ## Deny root, keep temp dirs and the project dir writable, network
  ## open. System dirs (/usr, /bin, /etc, ...) are read-only via the
  ## sandwall baseline; deny / fences the rest, home included. The
  ## POSIX `allow *` passes all traffic through the wall proxy; Windows
  ## has no host rules because there they would airgap the AppContainer
  ## (the net fence is a separate backend), while no rules grants it
  ## the internet capability.
  when defined(windows):
    "deny /\n" &
    "allow ~/AppData/Local/Temp\n" &
    "allow\n"
  else:
    "deny /\n" &
    "allow /tmp\n" &
    "allow /var/tmp\n" &
    "allow\n" &
    "allow *\n"

proc repoPolicyPath*(projectDir: string): string =
  projectDir / PolicyFile

proc systemPolicyPath*(): string =
  getConfigDir() / "3code" / UserPolicyFile

export Policy, defaultPolicyText, repoPolicyPath, systemPolicyPath,
       PolicyFile, UserPolicyFile

var
  current*: Policy
    ## The effective policy. When `active` is false, this is
    ## empty and every check allows.
  active*: bool = false
    ## False means no policy was loaded and bash runs unrestricted.
  procboxExe*: string = ""
    ## Path to the binary to exec for `sandbox restrict` (this one).
  lastMtime: Time

proc activePolicyPath*(projectDir: string): string =
  ## The one policy file in effect: the repo `.sandboxrc` when it
  ## exists, else the user file. Never both.
  let repo = repoPolicyPath(projectDir)
  if fileExists(repo): repo else: systemPolicyPath()

proc readPolicyText*(projectDir: string): string =
  ## The active file's contents, or the built-in default when no
  ## policy file exists at all: the sandbox stays on either way.
  let f = activePolicyPath(projectDir)
  if fileExists(f): readFile(f) else: defaultPolicyText()

proc defaultPolicyFilePath*(projectDir: string): string =
  ## Path to a file holding the effective policy text for
  ## `projectDir`, creating one in the per-run temp area when no repo
  ## or user policy file exists. The bash box child only accepts a
  ## file (`3code sandbox --policy`), so the in-memory default needs
  ## this materialization; the user file is never written.
  let f = activePolicyPath(projectDir)
  if fileExists(f): return f
  let dir = tempDir() / ("3code-default-policy-" & $getCurrentProcessId())
  createDir(dir)
  let p = dir / PolicyFile
  writeFile(p, defaultPolicyText())
  p

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
    ## The effective policy text the proxy enforces: the active policy
    ## file's contents, matching loadPolicy.
    let f = activePolicyPath(projectDir)
    (if fileExists(f): readFile(f) else: "") & "\n"

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
      wallProxyDir = tempDir() / ("3code-wall-" & $getCurrentProcessId())
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
    ## Rewrite the proxy's policy file after a reload; the proxy
    ## hot-reloads on mtime.
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
    let tmp = tempDir()
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
  ## `sandbox restrict <tmpdir> -- true`; success means the kernel applies the
  ## domain. Fails on kernels built without Landlock, runners under a
  ## seccomp filter that blocks the syscall, etc. Callers clear `procboxExe`
  ## when this returns false so the bash tool falls back to the unconfined
  ## setsid path rather than failing every bash command.
  if exe.len == 0: return false
  let tmp = tempDir() / ("3code-probe-" & $getCurrentProcessId())
  try:
    if not dirExists(tmp): createDir(tmp)
    # Capture (discard) stdout+stderr so a failing backend's OSError
    # traceback never leaks into the parent's output, which would trip
    # tests that assert no "unhandled exception" appears.
    let (outp, code) = execCmdEx(
      quoteShell(exe) & " sandbox restrict " & quoteShell(tmp) &
        " -- true </dev/null >/dev/null 2>&1")
    discard outp
    result = code == 0
  except CatchableError:
    result = false

proc mtimeOf(path: string): Time =
  try: getLastModificationTime(path)
  except OSError: fromUnix(0)

proc loadPolicy*(projectDir: string): Policy =
  ## Load the active policy file and remember its mtime for
  ## reloadIfChanged.
  lastMtime = mtimeOf(activePolicyPath(projectDir))
  sandwall.parsePolicy(readPolicyText(projectDir), projectDir)

proc reloadIfChanged*(projectDir: string): bool =
  ## Re-load the policy when the active file changed on disk since the
  ## last load. Returns true when a reload happened. Called before
  ## every restricted operation so a mid-session policy edit takes
  ## effect on the next tool call.
  if not active: return false
  let now = mtimeOf(activePolicyPath(projectDir))
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
  "policy: " & activePolicyPath(getCurrentDir())

proc sandboxPathInCwd*(): string =
  ## The repo-level policy file for the current working directory.
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
  ## reloading the policy first when the file changed. This is the
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
  of akReadOnly:
    if not needsWrite: (true, "")
    else:
      (false, "sandbox: " & resolved & " is read-only (" & policyHint() & ")")
  of akDeny:
    (false, "sandbox: " & resolved & " is denied by the policy (" & policyHint() & ")")

proc ensureRepoPolicy*(dir: string): bool =
  ## Materialize `dir/.sandboxrc` from the effective policy text (the
  ## user file when one exists, else the built-in default). Runs
  ## before the first `:sandbox allow|readonly|deny` edit so project
  ## rules start from the user's baseline, not from scratch.
  let path = repoPolicyPath(dir)
  if fileExists(path): return true
  try:
    writeFile(path, readPolicyText(dir))
  except CatchableError:
    return false
  fileExists(path)

proc renderSandbox*(p: Policy): string =
  renderPolicy(p)

proc appendRule*(sandboxFile, argPath: string; access: AccessKind): bool =
  ## Append a rule to the repo policy file, materializing it from the
  ## user file first when absent. Used by `:sandbox allow|deny|readonly`.
  ## After appending, reload so the change is live for the next check.
  if not fileExists(sandboxFile):
    if not ensureRepoPolicy(sandboxFile.parentDir): return false
  result = sandwall.appendRule(sandboxFile, argPath, access)
  if result:
    current = loadPolicy(getCurrentDir())

proc editPolicy*(sandboxFile: string): string =
  ## Open the repo policy file in $VISUAL/$EDITOR (falling back to vi
  ## on POSIX, notepad on Windows), materializing it from the user file
  ## first when absent. Blocks until the editor quits, then reloads so
  ## the edit is live for the next check. Returns a user-facing status
  ## line; a leading "error:" marks failure.
  if not fileExists(sandboxFile):
    if not ensureRepoPolicy(sandboxFile.parentDir):
      return "error: could not create sandbox file at " & sandboxFile
  let editor = getEnv("VISUAL", getEnv("EDITOR",
    when defined(windows): "notepad" else: "vi"))
  let code = execShellCmd(editor & " " & quoteShell(sandboxFile))
  if code != 0:
    return "error: editor exited with status " & $code
  current = loadPolicy(getCurrentDir())
  "sandbox updated: edited " & sandboxFile

