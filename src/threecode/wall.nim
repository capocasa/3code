## `3code wall` - the network firewall subcommands.
##
## The wall half of sandwall ships as library code only; like `3code
## box` for the filesystem, these are the trivial mains folded into the
## 3code binary so nothing separate needs bundling. Dispatched before
## any other startup (threecode.nim): the proxy and connect children
## must not pay for TLS/config/session init.
##
## Subcommands:
##   proxy   - foreground CONNECT+SOCKS5 allowlist proxy (the parent
##             3code process uses the in-library startWallProxy
##             instead; this subcommand is for standalone/debug use)
##   connect - SOCKS5 stdio pump for git ProxyCommand
##   setup-windows - one-time elevated Windows fence setup
##   wfp-probe - internal: egress probe run AS the sandwall user

when defined(posix):
  import std/posix except Time
import std/[os, strutils]
import sandwall, sandwall/wall
import sandbox
import sandbox as sb

const usage = """
3code wall - filesystem sandbox + network firewall

Usage:
  3code wall [--policy FILE ...] restrict [RWPATH ...] [--ro ROPATH ...] -- CMD [ARGS ...]
      Run CMD confined to the writable paths (full access), the
      read-only paths (read+execute), and nothing else. With --policy
      the path sets come from the given policy file (relative targets
      resolve against the project dir); explicit paths union with the
      policy sets. CMD and its children are confined: writes outside
      the allowed paths fail with EACCES. System dirs are always
      read-only so binaries, libs and device nodes stay runnable.
      Examples:
        3code wall restrict /tmp /home/me/work -- ls -la
        3code wall --policy .wallrc restrict -- make test

  Network subcommands:
  3code wall proxy --policy FILE [--project DIR] [--port N] [--unix SOCK] [-v]
      Run the CONNECT+SOCKS5 allowlist proxy on 127.0.0.1 in the
      foreground. --port 0 = ephemeral, printed to stdout as "port: N".
      --unix adds an AF_UNIX listener for netns-bridged children.

  3code wall connect HOST PORT
      SOCKS5 client pump for git ProxyCommand: stdio <-> proxy at
      127.0.0.1:$WALL_PROXY_PORT (default 1080) <-> HOST:PORT. Blocks.

  3code wall setup-windows [--status] [--uninstall]
      (Windows only) Elevated one-time setup: create the sandwall user
      and install the WFP filters. --status is non-elevated.

  3code wall wfp-probe
      (Windows only) Internal: run AS the sandwall user by the
      behavioral fence check. Exits 0 iff egress is blocked.
"""

when defined(posix):
  # sandwall's proxy/connect modules are POSIX-only (gated in sandwall's
  # wall.nim), so these mains are too.
  proc proxyMain(args: seq[string]): int =
    var policy, projectDir, unixSock = ""
    var port = 0'u16
    var verbose = false
    var i = 0
    while i < args.len:
      case args[i]
      of "--policy":
        inc i
        if i >= args.len: stderr.writeLine("Error: --policy needs a file"); return 2
        policy = args[i]
      of "--project":
        inc i
        if i >= args.len: stderr.writeLine("Error: --project needs a dir"); return 2
        projectDir = args[i]
      of "--port":
        inc i
        if i >= args.len: stderr.writeLine("Error: --port needs a number"); return 2
        try: port = uint16(parseInt(args[i]))
        except ValueError: stderr.writeLine("Error: bad port"); return 2
      of "--unix":
        inc i
        if i >= args.len: stderr.writeLine("Error: --unix needs a path"); return 2
        unixSock = args[i]
      of "-v":
        verbose = true
      else:
        stderr.writeLine("Error: unknown proxy option " & args[i]); return 2
      inc i
    if policy.len == 0:
      # Default to the active policy file (repo `.wallrc` when
      # present, else the user file).
      policy = sb.activePolicyPath(getCurrentDir())
    if projectDir.len == 0:
      projectDir = getCurrentDir()
    let p = startWallProxy(policy, projectDir, unixSockPath = unixSock,
                           port = port, verbose = verbose)
    echo "port: ", p.port
    # Park forever; SIGTERM/SIGINT default-kill, listeners die with us.
    while true: discard posix.pause()

  proc connectMain(args: seq[string]): int =
    if args.len != 2:
      stderr.writeLine("Error: connect needs HOST PORT"); return 2
    let port = try: uint16(parseInt(args[1]))
               except ValueError: stderr.writeLine("Error: bad port"); return 2
    let proxyPort = try: uint16(parseInt(getEnv("WALL_PROXY_PORT", "1080")))
                    except ValueError: 1080'u16
    socksConnect(proxyPort, args[0], port)

# ------------------------------------------------------------ restrict
#
# The sandwall CLI (`sandwall restrict ...`) folded into 3code so we
# ship one binary. The bash tool wraps each command as `3code wall
# --policy FILE restrict [--ro TMPDIR] -- sh -c <script>`: it re-execs
# *itself* (via `getAppFilename`), so there is no PATH lookup and no
# separate sandwall binary to find or bundle. The child loads the
# policy file itself, so every launch enforces the freshest contents.
# Policy files are force-added read-only so the confined command can
# read its own policy but not change it.

type
  RestrictArgs = object
    policies: seq[string]
    writable: seq[string]
    readOnly: seq[string]
    cmd: seq[string]

proc parseRestrictArgs(args: seq[string]): tuple[a: RestrictArgs, err: string] =
  ## Parse `wall restrict` args: global --policy options, explicit paths,
  ## `--` command separator.
  var a: RestrictArgs
  var seenSep = false
  var seenRo = false
  var i = 0
  while i < args.len:
    let arg = args[i]
    if seenSep:
      a.cmd.add(arg)
    elif arg == "--":
      seenSep = true
    elif arg == "--ro":
      seenRo = true
    elif arg == "--policy":
      inc i
      if i >= args.len:
        return (a, "--policy needs a file argument")
      a.policies.add(args[i])
    elif arg == "-h" or arg == "--help":
      stdout.writeLine(usage); quit(0)
    elif arg == "restrict":
      discard  # subcommand marker, already consumed by wallMain
    elif seenRo:
      a.readOnly.add(arg)
    else:
      a.writable.add(arg)
    inc i
  (a, "")

proc resolveRestrictPolicy(a: RestrictArgs): tuple[writable, readonly,
    denied: seq[string]; fence: bool] =
  ## Resolve the policy file(s) plus explicit args into the
  ## (writable, readonly, denied) triple. Policy files are force-added
  ## read-only. `denied` carries the policy's last-wins narrowing (a deny
  ## under an allowed root); the backend enforces it on top of the root
  ## lists.
  var writable = a.writable
  var readonly = a.readOnly
  var denied: seq[string]
  var hostRules = 0
  if a.policies.len > 0:
    # Exactly one active policy file: 3code passes the repo `.wallrc`
    # when it exists, else the user file. Multiple --policy args are
    # still accepted (concatenated) for standalone wall use.
    var texts: seq[string]
    for f in a.policies:
      texts.add(if fileExists(f): readFile(f) else: "")
    # Relative targets resolve against the project dir: the parent of
    # the last `.wallrc` policy file, falling back to cwd.
    let last = a.policies[^1]
    var projectDir = getCurrentDir()
    if last.extractFilename == PolicyFile:
      projectDir = last.parentDir
    var combined = ""
    for t in texts: combined.add t & "\n"
    let pol = parsePolicy(combined, projectDir)
    let r = pol.resolve()
    writable.add r.writable
    readonly.add r.readonly
    denied.add r.denied
    hostRules = r.hosts.len
    # The confined command may read its policy but never change it.
    for f in a.policies:
      if fileExists(f): readonly.add f
  (writable, readonly, denied, hostRules > 0)

proc restrictMain(args: seq[string]): int =
  ## Parse the `wall restrict` args and confine-then-exec. Returns the
  ## process exit code.
  let (a, err) = parseRestrictArgs(args)
  if err.len > 0:
    stderr.writeLine(usage)
    stderr.writeLine("\nError: " & err)
    return 2
  let (writable, readOnly, denied, fence) = resolveRestrictPolicy(a)
  if writable.len == 0 and a.policies.len == 0:
    stderr.writeLine(usage)
    stderr.writeLine("\nError: no writable paths given")
    return 2
  if a.cmd.len == 0:
    stderr.writeLine(usage)
    stderr.writeLine("\nError: no command given (use -- before the command)")
    return 2

  # System dirs (/usr, /bin, /lib, /dev/*, etc.) are auto-added as
  # read-only inside each sandwall backend's restrictImpl (baseline.nim),
  # so the command's binaries, libs, and device nodes stay accessible
  # without listing them here.
  # Network wall: the first host rule in the policy fences egress.
  # The parent (streamexec) runs the wall proxy and tells the child
  # where it is via WALL_PROXY_PORT (loopback port) and WALL_PROXY_SOCK
  # (its unix listener, the Linux netns bridge target). Standalone wall
  # with host rules but no proxy env fences with no egress at all -
  # correct fail-closed behaviour.
  let wallPort = try: uint16(parseInt(getEnv("WALL_PROXY_PORT", "0")))
                 except ValueError: 0'u16
  let wallSock = getEnv("WALL_PROXY_SOCK", "")

  when defined(windows):
    # Windows cannot confine the current process; restrict() only prepares
    # the token and stamps ACLs. runSandboxed spawns the child with that
    # token and rolls the ACLs back in a defer. fenceNet is ignored: the
    # Windows wall is keyed on the sandwall user's SID and lives on the
    # spawn path (see sandwall wall/winuser.nim).
    try:
      return int(runSandboxed(writable, a.cmd, read = readOnly,
                              denied = denied, inetOk = fence))
    except CatchableError as e:
      stderr.writeLine("3code wall: " & e.msg)
      return 127
  else:
    # posix: confine this process, then exec into CMD. Children inherit
    # the domain, so the parent restricting itself before exec is enough.
    #
    # setsid() runs before restrict+exec so CMD lands in its own session
    # and process group. The bash tool signals the whole group on
    # cancel/timeout; without setsid those signals would miss CMD's children.
    discard setsid()
    when defined(linux):
      restrict(writable, read = readOnly, denied = denied,
               fenceNet = fence, proxyPort = wallPort,
               proxySockPath = wallSock)
    else:
      restrict(writable, read = readOnly, denied = denied,
               fenceNet = fence, proxyPort = wallPort)
    try:
      exec(a.cmd)
    except CatchableError as e:
      stderr.writeLine("3code wall: " & e.msg)
      return 127

proc wallMain*(args: seq[string]): int =
  ## Entry for the `3code wall` subcommand. `args` is the full argv
  ## after `wall`. Global options (--policy) may precede `restrict`.
  if args.len == 0 or args[0] == "-h" or args[0] == "--help":
    stdout.writeLine(usage)
    return 0
  # hoist leading global --policy options (the restrict form)
  var rest = args
  var policies: seq[string]
  var i = 0
  while i < rest.len:
    if rest[i] == "--policy" and i + 1 < rest.len:
      policies.add(rest[i + 1])
      rest.delete(i + 1)
      rest.delete(i)
    else:
      inc i
  if rest.len > 0 and rest[0] == "restrict":
    var forwarded: seq[string]
    for p in policies:
      forwarded.add ["--policy", p]
    return restrictMain(forwarded & rest[1 .. ^1])
  case rest[0]
  of "proxy":
    when defined(posix):
      proxyMain(args[1 .. ^1])
    else:
      stderr.writeLine("Error: wall proxy is POSIX-only"); return 2
  of "connect":
    when defined(posix):
      connectMain(args[1 .. ^1])
    else:
      stderr.writeLine("Error: wall connect is POSIX-only"); return 2
  of "setup-windows":
    when defined(windows):
      if "--status" in args:
        let st = fenceStatus()
        let ast = acFenceStatus()
        echo "user fence: installed=", st.installed, " filters=", st.filters
        echo "ac fence:   installed=", ast.installed, " filters=", ast.filters
        if st.hint.len > 0: echo "  ", st.hint
        if ast.hint.len > 0: echo "  ", ast.hint
        return 0
      if "--uninstall" in args:
        uninstallFence()
        uninstallAcFence()
        echo "wall filters removed"
        return 0
      try:
        let sid = setupSandwallUser()
        installFence(sid, FirstProxyPort, LastProxyPort)
        try:
          installAcFence()
          echo "ac fence installed"
        except OSError as e:
          stderr.writeLine("3code wall: AC fence install failed: " & e.msg)
        echo "wall setup complete; sandwall user SID ", sid
        return 0
      except OSError as e:
        stderr.writeLine("3code wall: " & e.msg)
        return 1
    else:
      echo "wall setup-windows is only needed on Windows"
      return 0
  of "wfp-probe":
    when defined(windows):
      wfpProbeMain()
    else:
      0  # nothing to fence on POSIX
  else:
    stderr.writeLine(usage)
    stderr.writeLine("\nError: unknown subcommand (expected proxy, " &
      "connect, setup-windows, wfp-probe or restrict)")
    return 2
