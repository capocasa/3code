## `3code wall` - the network firewall subcommands.
##
## The wall half of sandwall ships as library code only; like `3code
## sandbox` for the filesystem, these are the trivial mains folded into the
## 3code binary so nothing separate needs bundling. Dispatched before
## any other startup (threecode.nim): the proxy and connect children
## must not pay for TLS/config/session init.
##
## Subcommands:
##   proxy   - foreground CONNECT+SOCKS5 allowlist proxy (the parent
##             3code process uses the in-library startWallProxy
##             instead; this subcommand is for standalone/debug use)
##   connect - SOCKS5 stdio pump for git ProxyCommand
##   wfp-probe - internal: egress probe run AS the sandwall user

when defined(posix):
  import std/posix except Time
import std/[os, strutils]
import sandwall, sandwall/wall
when defined(windows):
  import sandwall/wall/stdio
import sandbox as sb

const usage = """
3code wall - internal network-firewall subcommands (not for users)

Usage:
  3code wall proxy --policy FILE [--project DIR] [--port N] [--unix SOCK] [-v]
      Run the CONNECT+SOCKS5 allowlist proxy on 127.0.0.1 in the
      foreground. --port 0 = ephemeral, printed to stdout as "port: N".
      --unix adds an AF_UNIX listener for netns-bridged children.

  3code wall connect HOST PORT
      SOCKS5 client pump for git ProxyCommand: stdio <-> proxy at
      127.0.0.1:$WALL_PROXY_PORT (default 1080) <-> HOST:PORT. Blocks.

  3code wall wfp-probe
      (Windows only) Internal: run AS the sandwall user by the
      behavioral fence check. Exits 0 iff egress is blocked.

  3code wall stdio-relay -- CMD [ARGS ...]
      (Windows only) Internal: the sandbox child's first hop. Opens
      NIMBOX_OUT_PIPE as stdout+stderr, spawns CMD inheriting it,
      forwards the exit code. See sandwall wall/stdio.nim.
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
      # Default to the active policy file (repo `.sandbox` when
      # present, else the user file, else a temp materialization of
      # the built-in default).
      policy = sb.defaultPolicyFilePath(getCurrentDir())
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

proc setupMain*(args: seq[string]): int =
  ## Entry for `3code setup` / `3code unsetup` (Windows only). Elevated
  ## one-time sandbox setup: create the sandwall user, install the WFP
  ## fences. Idempotent; failures are reported and fail the command.
  when defined(windows):
    if args.len > 0 and args[0] in ["--status", "status"]:
      let st = fenceStatus()
      echo "fence: installed=", st.installed, " filters=", st.filters
      if st.hint.len > 0: echo "  ", st.hint
      return 0
    try:
      let sid = setupSandwallUser()
      installFence(sid, FirstProxyPort, LastProxyPort)
      echo "fence installed; sandwall user SID ", sid
      # The AC fence covers the legacy AppContainer backend; its
      # re-install over existing filters is best-effort.
      try:
        installAcFence()
      except OSError as e:
        stderr.writeLine("3code setup: legacy AC fence not refreshed: " & e.msg)
      echo "setup complete"
      return 0
    except OSError as e:
      stderr.writeLine("3code setup: " & e.msg)
      return 1
  else:
    stderr.writeLine("3code setup is only available on Windows")
    return 2

proc unsetupMain*(args: seq[string]): int =
  ## Entry for `3code unsetup` (Windows only): remove the WFP fences.
  ## Best-effort; safe to run repeatedly. Leaves the sandwall user and
  ## its DPAPI credentials in place (uninstalling a user with an active
  ## password policy is riskier than leaving a dormant account).
  when defined(windows):
    try:
      uninstallFence()
      uninstallAcFence()
      echo "fence removed"
      return 0
    except OSError as e:
      stderr.writeLine("3code unsetup: " & e.msg)
      return 1
  else:
    stderr.writeLine("3code unsetup is only available on Windows")
    return 2

proc wallMain*(args: seq[string]): int =
  ## Entry for the `3code wall` subcommand. `args` is the full argv
  ## after `wall`.
  if args.len == 0 or args[0] == "-h" or args[0] == "--help":
    stdout.writeLine(usage)
    return 0
  case args[0]
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
  of "wfp-probe":
    when defined(windows):
      wfpProbeMain()
    else:
      0  # nothing to fence on POSIX
  of "stdio-relay":
    when defined(windows):
      if args.len < 3 or args[1] != "--":
        stderr.writeLine("Error: stdio-relay needs -- CMD")
        return 2
      stdio.relayMain(args[2 .. ^1])
    else:
      stderr.writeLine("Error: stdio-relay is Windows-only"); return 2
  else:
    stderr.writeLine(usage)
    stderr.writeLine("\nError: unknown subcommand (expected proxy, " &
      "connect, wfp-probe or stdio-relay)")
    return 2
