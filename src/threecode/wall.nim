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
when defined(windows):
  # `3code setup` elevation: NetUserAdd and the WFP install need an
  # admin token (the notorious "netapi error 5" otherwise). A caller
  # that is not elevated relaunches itself with the runas verb so
  # Windows shows the UAC consent screen; the elevated child writes
  # its output to a log the unelevated parent relays.
  import std/[winlean, widestrs]

  const
    tokenQuery = 0x0008'i32
    tokenElevation = 20'i32
    seeMaskNoCloseProcess = 0x00000040'u32
    seeMaskNoAsync = 0x00000100'u32
    swHide = 0'i32
    errorCancelled = 1223'i32

  type
    TokenElevation {.bycopy.} = object
      tokenIsElevated: DWORD

    ShellExecuteInfoW {.bycopy.} = object
      cbSize: DWORD
      fMask: uint32
      hwnd: Handle
      lpVerb: WideCString
      lpFile: WideCString
      lpParameters: WideCString
      lpDirectory: WideCString
      nShow: int32
      hInstApp: Handle
      lpIDList: pointer
      lpClass: WideCString
      hkeyClass: Handle
      dwHotKey: DWORD
      hIcon: Handle
      hProcess: Handle

  proc shellExecuteExW(info: ptr ShellExecuteInfoW): WINBOOL {.stdcall,
      dynlib: "shell32", importc: "ShellExecuteExW".}
  proc getCurrentProcess(): Handle {.stdcall, dynlib: "kernel32",
      importc: "GetCurrentProcess".}
  proc openProcessToken(processHandle: Handle; desiredAccess: DWORD;
      tokenHandle: ptr Handle): WINBOOL {.stdcall, dynlib: "advapi32",
      importc: "OpenProcessToken".}
  proc getTokenInformation(tokenHandle: Handle; infoClass: int32;
      tokenInformation: pointer; infoLen: DWORD;
      returnLen: ptr DWORD): WINBOOL {.stdcall, dynlib: "advapi32",
      importc: "GetTokenInformation".}
  proc getCurrentProcessId(): DWORD {.stdcall, dynlib: "kernel32",
      importc: "GetCurrentProcessId".}
  proc processIdToSessionId(pid: DWORD; sessionId: ptr DWORD): WINBOOL
      {.stdcall, dynlib: "kernel32", importc: "ProcessIdToSessionId".}
  proc cDup2(src, dst: cint): cint {.importc: "_dup2", header: "<io.h>".}

  proc inSessionZero(): bool =
    # sshd / service children live in the non-interactive session 0,
    # where a runas relaunch can never show the UAC consent and
    # ShellExecuteExW blocks forever instead (verified on Win11).
    var sid: DWORD
    if processIdToSessionId(getCurrentProcessId(), addr sid) == 0:
      return true
    sid == 0

  proc isElevated(): bool =
    var tok: Handle
    if openProcessToken(getCurrentProcess(), tokenQuery, addr tok) == 0:
      return false
    defer: discard closeHandle(tok)
    var elev: TokenElevation
    var len: DWORD
    if getTokenInformation(tok, tokenElevation, addr elev,
        DWORD(sizeof(elev)), addr len) == 0:
      return false
    elev.tokenIsElevated != 0

  proc runSetup(): int =
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
      0
    except OSError as e:
      stderr.writeLine("3code setup: " & e.msg)
      1

  proc runUnsetup(): int =
    try:
      uninstallFence()
      uninstallAcFence()
      echo "fence removed"
      0
    except OSError as e:
      stderr.writeLine("3code unsetup: " & e.msg)
      1

  proc sharedSetupLog(kind: string): string =
    # A path both the unelevated caller and the elevated child (which
    # may be a different account when foreign admin credentials go
    # into the prompt) can write: %ProgramData% inherits Users
    # write-data and Admins full control. Falls back to temp.
    let name = "3code-" & kind & ".log"
    let pd = getEnv("ProgramData", "")
    if pd.len > 0: pd / name
    else: getTempDir() / name

  proc elevateMain(kind: string): int =
    # Relaunch `3code <kind>` elevated through the UAC consent screen
    # and relay the child's output. Returns the child's exit code, or
    # -1 when the prompt could not be shown or was declined.
    let log = sharedSetupLog(kind)
    if fileExists(log):
      try: removeFile(log)
      except OSError: discard
    var sei = ShellExecuteInfoW(
      cbSize: DWORD(sizeof(ShellExecuteInfoW)),
      fMask: seeMaskNoCloseProcess or seeMaskNoAsync,
      lpVerb: newWideCString("runas"),
      lpFile: newWideCString(getAppFilename()),
      lpParameters: newWideCString(kind & " --elevated \"" & log & "\""),
      nShow: swHide)
    if shellExecuteExW(addr sei) == 0:
      let e = getLastError()
      stderr.writeLine("3code " & kind & ": admin rights " &
        (if e == errorCancelled: "request was declined"
         else: "prompt failed (error " & $e & ")"))
      return -1
    discard waitForSingleObject(sei.hProcess, INFINITE)
    var code: int32
    discard getExitCodeProcess(sei.hProcess, code)
    discard closeHandle(sei.hProcess)
    if fileExists(log):
      try: stdout.write(readFile(log))
      except OSError: discard
      try: removeFile(log)
      except OSError: discard
    int(code)

  proc elevatedChild(body: proc(): int; logPath: string): int =
    # The UAC-elevated re-run's body: stdout and stderr are dup2'd
    # onto the caller's log so the unelevated parent can relay them.
    let f: File = try: open(logPath, fmWrite)
                  except IOError: nil
    if f != nil:
      discard cDup2(cint(getFileHandle(f)), 1.cint)
      discard cDup2(cint(getFileHandle(f)), 2.cint)
    result = body()
    if f != nil: close(f)
    flushFile(stdout)
    flushFile(stderr)

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
  ## Entry for `3code setup` / `3code unsetup` (Windows only). One-time
  ## sandbox setup: create the sandwall user, install the WFP fences.
  ## Idempotent; failures are reported and fail the command. Without
  ## an elevated token, relaunches itself through the UAC prompt.
  when defined(windows):
    if args.len > 0 and args[0] in ["--status", "status"]:
      let st = fenceStatus()
      if st.hint.len > 0:
        # Denied, not absent: say unknown rather than installed=false.
        echo "fence: unknown (", st.hint, ")"
      else:
        echo "fence: installed=", st.installed, " filters=", st.filters
      return 0
    # Internal: the UAC-elevated re-run (see elevatedChild).
    if args.len == 2 and args[0] == "--elevated":
      return elevatedChild(runSetup, args[1])
    if not isElevated():
      if inSessionZero():
        stderr.writeLine("3code setup: admin rights are required, and " &
          "this ssh/service session cannot show the UAC prompt. Run " &
          "'3code setup' from an elevated shell, the Windows console, " &
          "or an RDP session")
        return 1
      stderr.writeLine("3code setup: admin rights are required; " &
        "requesting them now (approve the UAC prompt)")
      let rc = elevateMain("setup")
      if rc == -1:
        stderr.writeLine("3code setup: admin rights are still needed; " &
          "use an elevated shell or approve the UAC prompt when it " &
          "shows")
        return 1
      return rc
    return runSetup()
  else:
    stderr.writeLine("3code setup is only available on Windows")
    return 2

proc unsetupMain*(args: seq[string]): int =
  ## Entry for `3code unsetup` (Windows only): remove the WFP fences.
  ## Best-effort; safe to run repeatedly. Leaves the sandwall user and
  ## its DPAPI credentials in place (uninstalling a user with an active
  ## password policy is riskier than leaving a dormant account).
  when defined(windows):
    # Internal: the UAC-elevated re-run (see elevatedChild).
    if args.len == 2 and args[0] == "--elevated":
      return elevatedChild(runUnsetup, args[1])
    # Removing the filters needs the same admin token setup does;
    # without elevation WFP denies the enum and the deletes outright.
    if not isElevated():
      if inSessionZero():
        stderr.writeLine("3code unsetup: admin rights are required, " &
          "and this ssh/service session cannot show the UAC prompt. " &
          "Run '3code unsetup' from an elevated shell, the Windows " &
          "console, or an RDP session")
        return 1
      stderr.writeLine("3code unsetup: admin rights are required; " &
        "requesting them now (approve the UAC prompt)")
      let rc = elevateMain("unsetup")
      if rc == -1:
        stderr.writeLine("3code unsetup: admin rights are still " &
          "needed; use an elevated shell or approve the UAC prompt " &
          "when it shows")
        return 1
      return rc
    return runUnsetup()
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
