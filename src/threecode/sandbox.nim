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
## file `.sandbox` when it exists, else the user file
## `~/.config/3code/sandbox` when the user wrote one, else the
## built-in default in memory. 3code never creates the user file, so a
## user who never configured anything always gets the current shipped
## default, not whatever default a long-ago first run froze to disk. A
## `:sandbox allow|readonly|deny` edit materializes the repo file from
## the effective policy text, so project rules start from the user's
## baseline instead of from scratch.
##
## The two policy file paths 3code can activate (the repo `.sandbox`
## and `~/.config/3code/sandbox`) are always read-only, no matter what
## the file says: they ride every load as hidden guard rules
## (`hiddenRules`), appended last so no file rule can weaken them,
## enforced by the in-process checks and carried through to the box
## subprocess, but never shown in `:sandbox show`.
##
## `reloadIfChanged` re-reads the active file when its mtime changed
## since the last load; it runs before every restricted operation
## (in-process read/write/patch checks and bash launches). The bash
## subprocess additionally loads the policy file itself
## (`3code sandbox --policy`), so a launch always enforces the freshest
## file contents even between parent reloads.

import std/[os, osproc, streams, strutils, times]
when defined(posix):
  from std/posix import kill, Pid
import sandwall
import sandwall/wall as sandwallWall
import types
import util

export sandwall.AccessKind, sandwall.Rule,
       sandwall.RuleKind, sandwall.parsePolicy, sandwall.checkPath,
       sandwall.renderPolicy, sandwall.resolve,
       sandwall.Resolved

const
  PolicyFile* = ".sandbox"
    ## The repo-level policy file, directly in the project root.
  UserPolicyFile* = "sandbox"
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
  ## the internet capability. The project dir is spelled `allow ./`
  ## (a bare `allow` is equivalent; the explicit target reads better).
  when defined(windows):
    "deny /\n" &
    "allow ~/AppData/Local/Temp\n" &
    "allow ./\n"
  else:
    "deny /\n" &
    "allow /tmp\n" &
    "allow /var/tmp\n" &
    "allow ./\n" &
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
  hiddenRules*: seq[Rule] = @[]
    ## Implicit guard rules appended after every parse: enforced by
    ## checkPath and the box backends, hidden from renderPolicy.
    ## initSandbox seeds it with the two policy file paths as
    ## read-only.

proc activePolicyPath*(projectDir: string): string =
  ## The one policy file in effect: the repo `.sandbox` when it
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
  ##
  ## The file is deliberately not named `.sandbox`: the box child
  ## resolves relative targets against the parent of a `.sandbox`-named
  ## policy file, which for a temp-dir materialization would redirect
  ## the default's `allow ./` from the project dir to the temp dir. A
  ## plain name falls through to cwd, which is the project dir.
  let f = activePolicyPath(projectDir)
  if fileExists(f): return f
  let dir = tempDir() / ("3code-default-policy-" & $getCurrentProcessId())
  createDir(dir)
  let p = dir / "policy"
  writeFile(p, defaultPolicyText())
  p

# ------------------------------------------------------------- wall proxy
#
# One wall proxy per 3code run, started lazily when the effective
# policy first shows host rules and shared by every fenced bash launch
# (the sandwall accept loop is sequential and fork-safe; per-launch
# proxies are both wasteful and wrong - see sandwall wall/proxy.nim).

var
  wallProxy: sandwallWall.WallProxy
    ## .sock == nil means not running.
  wallProxyBoundDir: string = ""
    ## The dir the running proxy's policy file lives in. On POSIX the
    ## unix listener is rebound when the bash tmp dir changes; Windows
    ## has no unix listener, only the loopback TCP port.

when defined(posix):
  var
    wallProxyDir*: string = ""
      ## Per-run temp dir holding the merged policy file + unix socket.

proc wallProxyNeeded*(pol: Policy): bool =
  ## Fencing is off until the effective policy names its first host.
  pol.resolve().hosts.len > 0

proc checkRawHost*(host: string; port: uint16): bool =
  ## The in-process half of the network fence, for tool calls that run
  ## in the parent and so never pass through the wall proxy (web_fetch).
  ## Applies the exact matcher the proxy consults per CONNECT/SOCKS5
  ## request, so both halves of a fenced session decide identically.
  ## Unfenced (no host rules / sandbox off) is the caller's business:
  ## this proc says allow and is only consulted when wallProxyNeeded.
  sandwallWall.toHostList(current.resolve().hosts).allows(host, port)

when defined(posix):

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

proc wallPolicyText*(projectDir: string): string =
  ## The effective policy text the proxy enforces: the active policy
  ## file's contents, matching loadPolicy.
  let f = activePolicyPath(projectDir)
  (if fileExists(f): readFile(f) else: "") & "\n"

proc wallProxyPolicyDir(): string =
  ## Temp dir holding the proxy's merged policy file.
  tempDir() / ("3code-wall-" & $getCurrentProcessId())

proc ensureWallProxy*(projectDir: string): bool =
  ## Start the per-run proxy when the policy needs it. On POSIX, when
  ## it is already running but bound in a different (since-deleted)
  ## bash tmp dir, restart it so the unix socket lives in the current
  ## launch's writable dir; the bridge connects there. True when
  ## fenced bash may launch.
  if not wallProxyNeeded(current): return false
  when defined(posix):
    if wallProxyDir.len == 0:
      wallProxyDir = wallProxyPolicyDir()
      createDir(wallProxyDir)
    if wallProxy.port != 0 and wallProxyBoundDir == wallProxyDir:
      return true
  else:
    if wallProxy.port != 0:
      return true
  if wallProxy.port != 0:
    sandwallWall.stopWallProxy(wallProxy)
    wallProxy.port = 0
  let dir = when defined(posix): wallProxyDir else: wallProxyPolicyDir()
  createDir(dir)
  let polFile = dir / "policy"
  writeFile(polFile, wallPolicyText(projectDir))
  try:
    when defined(posix):
      wallProxy = sandwallWall.startWallProxy(polFile, projectDir,
        port = 0, unixSockPath = proxySockPath())
    else:
      # port = 0 picks a free port in the WFP fence range on Windows
      wallProxy = sandwallWall.startWallProxy(polFile, projectDir)
    wallProxyBoundDir = dir
  except CatchableError as e:
    raise newException(IOError, "wall proxy: " & e.msg)
  true

proc wallProxyPort*(): uint16 =
  ## The proxy's loopback port; 0 when not running.
  wallProxy.port

proc syncWallProxyPolicy*(projectDir: string) =
  ## Rewrite the proxy's policy file after a reload; the proxy
  ## hot-reloads on mtime.
  if wallProxy.port == 0 or wallProxyBoundDir.len == 0: return
  writeFile(wallProxyBoundDir / "policy", wallPolicyText(projectDir))

proc stopWall*() =
  ## Proxy + temp dir teardown, called from 3code's cleanup exit proc.
  if wallProxy.port != 0:
    sandwallWall.stopWallProxy(wallProxy)
    wallProxy.port = 0
    wallProxyBoundDir = ""
  when defined(posix):
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

when defined(posix):
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

const ProbeTimeoutMs = 2000
  ## Cap on the POSIX restrict probe. A hang is unknown, not "backend
  ## broken": callers treat false as permission to clear procboxExe and
  ## run every bash command unconfined.

proc backendWorks*(exe: string): bool =
  ## Whether the OS-native sandbox backend can restrict on this host.
  ## Callers clear `procboxExe` when this returns false so the bash tool
  ## falls back to the unconfined setsid path rather than failing every
  ## bash command.
  ##
  ## Windows: a setup check, not a restrict exec. `CreateProcessWithLogonW`
  ## of this same 3code.exe as the sandwall user is what first-launch
  ## Defender/SmartScreen can block for minutes; `backendSupported` is
  ## the user+creds test and does not spawn. Missing setup is false.
  ##
  ## POSIX: re-execs this binary as `sandbox restrict <tmpdir> -- true`.
  ## Success means the kernel applied the domain. A real nonzero exit
  ## (no Landlock, seccomp-blocked syscall) is false. A hang past
  ## ProbeTimeoutMs is unknown-success (true) so a stuck probe does not
  ## silently disable confinement.
  if exe.len == 0: return false
  when defined(windows):
    result = backendSupported()
  else:
    let tmp = tempDir() / ("3code-probe-" & $getCurrentProcessId())
    try:
      if not dirExists(tmp): createDir(tmp)
      # poStdErrToStdOut + a drain of the pipe so a failing backend's
      # OSError traceback never leaks into the parent's output (tests
      # assert no "unhandled exception" appears). Redirects stay off
      # the argv: they would reach the probe child as arguments.
      var p = startProcess(exe,
        args = ["sandbox", "restrict", tmp, "--", "true"],
        options = {poStdErrToStdOut})
      let deadline = epochTime() + ProbeTimeoutMs / 1000
      var code = -1
      while epochTime() < deadline:
        code = p.peekExitCode
        if code != -1: break
        sleep(20)
      if code == -1:
        try: p.kill() except CatchableError: discard
        try: discard p.waitForExit() except CatchableError: discard
        result = true
      else:
        result = code == 0
      try:
        discard p.outputStream.readAll()
      except CatchableError:
        discard
      p.close()
      try: removeDir(tmp) except CatchableError: discard
    except CatchableError:
      result = false

proc mtimeOf(path: string): Time =
  try: getLastModificationTime(path)
  except OSError: fromUnix(0)

proc guardRules*(projectDir: string): seq[Rule] =
  ## Hidden read-only rules covering the two policy file paths 3code
  ## can make active (the repo `.sandbox` and the user file), so
  ## neither the in-process tools nor the sandboxed command can change
  ## the policy out from under 3code, no matter what the file says.
  ## Appended last after every load; a repo file that is also the user
  ## file collapses to one rule.
  let user = systemPolicyPath()
  result = @[Rule(access: akReadOnly, kind: rkPath, hidden: true,
                  path: repoPolicyPath(projectDir))]
  if user != result[0].path:
    result.add Rule(access: akReadOnly, kind: rkPath, hidden: true,
                    path: user)

proc loadPolicy*(projectDir: string): Policy =
  ## Load the active policy file and remember its mtime for
  ## reloadIfChanged. Guard rules (`hiddenRules`) are appended last so
  ## no rule in the file can weaken them.
  lastMtime = mtimeOf(activePolicyPath(projectDir))
  result = sandwall.parsePolicy(readPolicyText(projectDir), projectDir)
  result.add hiddenRules

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
  ## Canonical form of `p`: ~-expanded, absolute, normalized, symlinks
  ## resolved, mirroring sandwall's normalize() so the in-process gate
  ## and the OS backends decide on the same string. Without this, a
  ## path like `<proj>/sub/../../etc` still starts with the project
  ## prefix as a raw string and isPathUnder lets it through. Write
  ## targets may not exist yet, so symlink resolution runs on the
  ## deepest existing ancestor and re-appends the tail (sandwall's
  ## canonicalForDisplay pattern). Empty for an empty input.
  if p.len == 0: return ""
  var q = p
  if q.startsWith("~"): q = expandTilde(q)
  let abs = try: absolutePath(q) except CatchableError: q
  result = abs.normalizedPath
  var dir = result
  var tail = ""
  while dir.len > 0:
    try:
      let r = expandFilename(dir)
      if r.len > 0:
        return if tail.len > 0: r & tail else: r
    except CatchableError:
      discard
    let (head, last) = splitPath(dir)
    if last.len == 0: break
    tail = DirSep & last & tail
    dir = head.normalizedPath


proc contractPolicyPath*(resolved: string): string =
  ## The user-facing form of an absolute cleaned path in sandbox
  ## messages: under the cwd as the portable relative form (`foo`,
  ## `./x`), under home as `~/...`, else absolute. Display only.
  sandwall.contractPath(resolved, getCurrentDir())

proc canonicalRules*(rules: Policy): Policy =
  ## The policy with every path rule root run through resolveRawPath,
  ## matching what the OS backends enforce: they canonicalize rule
  ## paths (sandwall paths.normalize, symlink-resolving) before handing
  ## them to Landlock/Seatbelt, so `allow ./` covers the project also
  ## when its path reaches through a symlink (macOS /var -> /private/var
  ## makes getTempDir and every fixture under it such a case). Rules
  ## stay literal in `current` so :sandbox rendering shows the paths the
  ## user wrote; only the comparison in checkRawPath sees canonical form.
  result = rules
  for i in 0 ..< result.len:
    if result[i].kind == rkPath:
      result[i].path = resolveRawPath(result[i].path)

proc checkRawPath*(path: string; needsWrite: bool): tuple[allowed: bool, reason: string] =
  ## Check a raw (possibly relative) path against the current policy,
  ## reloading the policy first when the file changed. This is the
  ## in-process gate for the read/write/patch tools; it applies the same
  ## ordered last-match-wins walk as sandwall `checkPath`, which the box
  ## subprocess enforces at the kernel level for bash. Both the query
  ## and the rule roots are canonicalized first so a symlinked project
  ## dir matches its own rules. `needsWrite = false` allows read-only and
  ## writable; `true` requires writable.
  if not active or not sandboxEnabled: return (true, "")
  discard reloadIfChanged(getCurrentDir())
  let resolved = resolveRawPath(path)
  if resolved.len == 0: return (true, "")
  let access = canonicalRules(current).checkPath(resolved)
  let shown = contractPolicyPath(resolved)
  case access
  of akWritable: (true, "")
  of akReadOnly:
    if not needsWrite: (true, "")
    else:
      (false, "sandbox: " & shown & " is read-only (" & policyHint() & ")")
  of akDeny:
    (false, "sandbox: " & shown & " is denied by the policy (" & policyHint() & ")")

proc ensureRepoPolicy*(dir: string): bool =
  ## Materialize `dir/.sandbox` from the effective policy text (the
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
  renderPolicy(p, getCurrentDir())

proc appendRule*(sandboxFile, argPath: string; access: AccessKind): bool =
  ## Append a rule to the repo policy file, materializing it from the
  ## user file first when absent. Used by `:sandbox allow|deny|readonly`.
  ## After appending, reload so the change is live for the next check.
  if not fileExists(sandboxFile):
    if not ensureRepoPolicy(sandboxFile.parentDir): return false
  result = sandwall.appendRule(sandboxFile, argPath, access,
    getCurrentDir())
  if result:
    current = loadPolicy(getCurrentDir())

proc editPolicy*(sandboxFile: string): string =
  ## Open the repo policy file in $VISUAL/$EDITOR (falling back to vi
  ## on POSIX, notepad on Windows), materializing it from the user file
  ## first when absent. Blocks until the editor quits, then reloads so
  ## the edit is live for the next check. Returns a user-facing status
  ## line; a leading "error:" marks failure.
  ##
  ## The editor string is deliberately passed through the shell
  ## unquoted, like git: `VISUAL="code -w"` must reach the shell as
  ## flags. An editor path containing spaces must be escaped by the
  ## user (`VISUAL="/opt/Visual Studio Code"` would try to exec
  ## `/opt/Visual`), same contract as $EDITOR everywhere else.
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

