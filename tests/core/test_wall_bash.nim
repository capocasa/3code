import std/[net, os, osproc, posix, strtabs, strutils, times, unittest]
import threecode/sandbox as sb
import sandwall/wall as sw

## Fenced-bash wiring: proxy env helper, per-run proxy lifecycle, and
## an end-to-end netns launch through `3code sandbox`. POSIX only; the e2e
## self-skips when the kernel can't unshare a netns.

const binName = when defined(windows): "3code.exe" else: "3code"
proc binPath(): string = getCurrentDir() / binName

suite "wall env helper":
  test "wallEnv carries proxy vars and conditional GIT_SSH_COMMAND":
    let e = sb.wallEnv("/x/3code", "12345", "/tmp/sock", "")
    var t = newStringTable()
    for (k, v) in e: t[k] = v
    check t["WALL_PROXY_PORT"] == "12345"
    check t["WALL_PROXY_SOCK"] == "/tmp/sock"
    check t["http_proxy"] == "http://127.0.0.1:12345"
    check t["https_proxy"] == "http://127.0.0.1:12345"
    check t["HTTP_PROXY"] == "http://127.0.0.1:12345"
    check t["HTTPS_PROXY"] == "http://127.0.0.1:12345"
    check t["ALL_PROXY"] == "socks5h://127.0.0.1:12345"
    check t["all_proxy"] == "socks5h://127.0.0.1:12345"
    when defined(linux):
      # the netns fence has no direct loopback: local targets must go
      # through the proxy too (the allowlist decides)
      check t["NO_PROXY"] == ""
    else:
      check "127.0.0.1" in t["NO_PROXY"]
    check t["GIT_SSH_COMMAND"].contains("wall connect %h %p")
    check t["GIT_SSH_COMMAND"].contains("/x/3code")
    # user-set GIT_SSH_COMMAND wins
    let e2 = sb.wallEnv("/x/3code", "12345", "", "ssh -i /key")
    for (k, v) in e2: check k != "GIT_SSH_COMMAND"
    for (k, v) in e2: check k != "WALL_PROXY_SOCK"  # no sock on macOS shape

when defined(posix):
  suite "wall ssh shim":
    test "installSshShim wraps the real ssh with a wall ProxyCommand":
      if findExe("ssh") == "":
        skip()
      else:
        let dir = getTempDir() / ("3code-sshshim-" & $getCurrentProcessId())
        createDir(dir)
        defer: removeDir(dir)
        let shimDir = sb.installSshShim(dir, "/x/3code")
        check shimDir == dir / "wallbin"
        let shim = readFile(shimDir / "ssh")
        check shim.startsWith("#!/bin/sh")
        check ("exec " & findExe("ssh").quoteShell) in shim
        check ("-F " & (shimDir / "ssh_config").quoteShell) in shim
        # the wall config carries the tunnel plus the pw_dir repairs
        # (fence uid is 65534; see wallSshConfig)
        let cfg = readFile(shimDir / "ssh_config")
        check "/x/3code wall connect %h %p" in cfg
        check "IdentityFile " in cfg
        check "UserKnownHostsFile " in cfg
        if fileExists(getHomeDir() / ".ssh/config"):
          check "~/" notin cfg
          # multiplexing cannot work on a readonly ~/.ssh, and a
          # ControlMaster bind failure is fatal in OpenSSH 10
          check "ControlMaster auto" notin cfg
          check "ControlPath ~/.ssh" notin cfg
        var st: Stat
        check posix.stat((shimDir / "ssh").cstring, st) == 0
        check (st.st_mode and 0o111) != 0  # executable
        # the wrapper must actually run: `-V` exits before any
        # connection, so this only exercises exec + option quoting
        let v = execCmdEx((shimDir / "ssh").quoteShell & " -V")
        check v.exitCode == 0
        check "OpenSSH" in v.output

suite "wall proxy lifecycle":
  test "proxy starts on host rules, reloads on policy rewrite":
    let dir = getTempDir() / ("3code-wallcycle-" & $getCurrentProcessId())
    createDir(dir)
    defer:
      sb.stopWall()
      removeDir(dir)
    writeFile(dir / ".sandbox", "deny /\nallow\nallow 127.0.0.1\n")
    sb.current = sb.loadPolicy(dir)
    check sb.wallProxyNeeded(sb.current)
    sb.active = true
    sb.moveWallSock(dir)  # writable, mirrors streamexec's tmp
    try:
      check sb.ensureWallProxy(dir)
    except IOError as e:
      echo "ENSURE FAILED: ", e.msg
      raise
    check sb.wallProxyPort() != 0
    # unix listener exists on linux
    when defined(linux):
      var st: Stat
      check posix.stat(sb.proxySockPath().cstring, st) == 0
    # reload propagation: rewrite the repo policy, sync, proxy file changes
    let polFile = sb.wallProxyDir / "policy"
    let before = readFile(polFile)
    writeFile(dir / ".sandbox", "deny /\nallow\nallow 127.0.0.1\nallow example.com\n")
    sb.syncWallProxyPolicy(dir)
    let after = readFile(polFile)
    check after != before
    check "example.com" in after
    sb.stopWall()
    check sb.wallProxyPort() == 0

  test "proxy rebinds when the launch tmp dir changes":
    # streamexec points the unix socket at the per-launch bash tmp
    # dir, which is deleted right after the command. The next launch
    # must rebind the proxy into its own tmp dir; without the rebind
    # the bridge connects to a dead socket (connection reset).
    let dirA = getTempDir() / ("3code-wallre-a-" & $getCurrentProcessId())
    let dirB = getTempDir() / ("3code-wallre-b-" & $getCurrentProcessId())
    createDir(dirA)
    createDir(dirB)
    defer:
      sb.stopWall()
      removeDir(dirA)
      removeDir(dirB)
    writeFile(dirA / ".sandbox", "deny /\nallow\nallow 127.0.0.1\n")
    sb.current = sb.loadPolicy(dirA)
    sb.active = true
    # first launch: bind in dirA
    sb.moveWallSock(dirA)
    check sb.ensureWallProxy(dirA)
    let portA = sb.wallProxyPort()
    check portA != 0
    when defined(linux):
      var st: Stat
      check posix.stat(sb.proxySockPath().cstring, st) == 0
    # streamexec deletes the launch dir after the command
    removeDir(dirA)
    createDir(dirA)  # policy file still lives here for loadPolicy
    writeFile(dirA / ".sandbox", "deny /\nallow\nallow 127.0.0.1\n")
    # second launch: new tmp dirB; the proxy must rebind there
    sb.moveWallSock(dirB)
    check sb.ensureWallProxy(dirA)
    when defined(linux):
      # proxySockPath is the bridge target on Linux; on macOS it is ""
      # by design (the sandbox reaches host loopback directly).
      check sb.proxySockPath() == dirB / "proxy.sock"
      check posix.stat(sb.proxySockPath().cstring, st) == 0
    # same dir again: no rebind, same port
    let portB = sb.wallProxyPort()
    sb.moveWallSock(dirB)
    check sb.ensureWallProxy(dirA)
    check sb.wallProxyPort() == portB

when defined(linux):
  suite "fenced bash end to end":
    test "netns: direct egress dies, proxy tunnel works":
      # Probe netns support with a trivial fenced launch first; skip
      # (don't fail) on kernels/containers without userns+netns.
      let dir = getTempDir() / ("3code-walle2e-" & $getCurrentProcessId())
      createDir(dir)
      defer: removeDir(dir)
      let pol = dir / "policy"
      writeFile(pol, "deny /\nallow " & dir & "\nallow " & getTempDir() & "\nallow 127.0.0.1\n")
      # echo server on host loopback
      let echoSock = newSocket(buffered = false)
      echoSock.setSockOpt(OptReuseAddr, true)
      echoSock.bindAddr(Port(0), "127.0.0.1")
      echoSock.listen()
      defer: echoSock.close()
      let echoPort = echoSock.getLocalAddr()[1]
      # in-test proxy with the unix sock in the writable dir
      var proxy = sw.startWallProxy(pol, dir, port = 0,
        unixSockPath = dir / "proxy.sock")
      defer: sw.stopWallProxy(proxy)
      let port = $int(proxy.port)
      # probe: fenced `true` succeeds only when netns works
      let probeEnv = {"WALL_PROXY_PORT": port,
        "WALL_PROXY_SOCK": dir / "proxy.sock"}.newStringTable
      let probe = startProcess(binPath(), args = ["sandbox", "--policy", pol,
        "restrict", "--", "true"], env = probeEnv,
        options = {poStdErrToStdOut})
      let probeOk = probe.waitForExit(15_000) == 0
      probe.close()
      if not probeOk:
        # unfenced fallback: sandwall warns and continues; e2e moot
        skip()
      else:
        # 1. direct TCP from inside the netns to the host echo server
        # must fail: the netns loopback has no echo server.
        # bash, not sh: /dev/tcp is a bashism (dash on CI lacks it).
        let r1 = execCmdEx(binPath() & " sandbox --policy " & pol.quoteShell &
          " restrict -- bash -c " &
          "'exec 3<>/dev/tcp/127.0.0.1/" & $int(echoPort) & "' </dev/null",
          env = probeEnv, options = {poDaemon})
        check r1.exitCode != 0
        # 2. the proxy bridge port answers inside the netns and the
        # allowlist tunnels: CONNECT via the bridge to the echo server.
        # head -c 20 MUST get its bytes: the echo side stays open, so
        # without a byte-count the read would hang; the 200 response
        # line is well under 20.
        let script = "'exec 3<>/dev/tcp/127.0.0.1/" & port &
          "; printf \"CONNECT 127.0.0.1:" & $int(echoPort) &
          " HTTP/1.1\\r\\n\\r\\n\" >&3; head -c 20 <&3'"
        # poDaemon: the bridge inherits the box stdout pipe, so
        # execCmdEx would wait for pipe EOF (bridge exit) after sh is
        # done; poDaemon detaches the grandchildren instead.
        let p2 = startProcess(binPath(), args = ["sandbox", "--policy", pol,
          "restrict", "--", "bash", "-c",
          "exec 3<>/dev/tcp/127.0.0.1/" & port &
          "; printf \"CONNECT 127.0.0.1:" & $int(echoPort) &
          " HTTP/1.1\\r\\n\\r\\n\" >&3; head -c 20 <&3"],
          env = probeEnv, options = {poStdErrToStdOut})
        var buf = newString(4096)
        var out2 = ""
        var drained = false
        for _ in 0 .. 100:  # up to 10s for the tunnel answer
          var fds = [TPollfd(fd: p2.outputHandle.cint, events: POLLIN,
                             revents: 0)]
          let pr = posix.poll(addr fds[0], 1, 100)
          if pr < 0: break
          if pr == 0:
            if drained: break
            continue
          let n = posix.read(p2.outputHandle, addr buf[0], 4096)
          if n <= 0:
            drained = true
            break
          out2.add buf[0 ..< n]
          if "200" in out2: break
        check "200" in out2
        p2.terminate()
        discard p2.waitForExit(5_000)
        p2.close()
        # The proxy is SEQUENTIAL (fork-safety, sandwall proxy.nim):
        # the CONNECT above stays open on the echo side until it is
        # accepted and closed here - accept BEFORE any further proxy
        # connection or the next one is never served. Bounded accept:
        # if nothing arrives the test must fail, not hang.
        var efd: SocketHandle = SocketHandle(-1)
        var waited = 0
        while efd.int < 0 and waited < 10_000:
          var afds = [TPollfd(fd: echoSock.getFd().cint, events: POLLIN,
                              revents: 0)]
          doAssert posix.poll(addr afds[0], 1, 100) >= 0
          if afds[0].revents != 0:
            efd = posix.accept(echoSock.getFd(), nil, nil)
          waited += 100
        check efd.int >= 0
        if efd.int >= 0: discard posix.close(efd)
        # 3. denied host through the proxy: 403
        let script3 = "'exec 3<>/dev/tcp/127.0.0.1/" & port &
          "; printf \"CONNECT denied.example:443 HTTP/1.1\\r\\n\\r\\n\" >&3" &
          "; head -c 20 <&3'"
        let r3 = execCmdEx(binPath() & " sandbox --policy " & pol.quoteShell &
          " restrict -- bash -c " & script3 & " </dev/null", env = probeEnv,
          options = {poDaemon})
        check "403" in r3.output

    test "netns: ssh tunnels through the wall shim, allowlisted":
      # The fence is protocol-agnostic at the proxy (SOCKS5 carries
      # any TCP); what makes ssh work is the PATH shim's ProxyCommand
      # (`wall connect`, DNS at the proxy) plus the bridge surviving
      # ssh's close_range(3, ...) fd hygiene (sandwall PDEATHSIG fix).
      # ssh itself must be present; the binary dir must be executable
      # inside the fence because the ProxyCommand re-execs 3code.
      if findExe("ssh") == "":
        skip()
      else:
        let dir = getTempDir() / ("3code-walle2e-ssh-" & $getCurrentProcessId())
        createDir(dir)
        defer: removeDir(dir)
        let pol = dir / "policy"
        writeFile(pol, "deny /\nallow " & dir & "\nallow " & getTempDir() &
          "\nallow " & getCurrentDir() & "\nallow 127.0.0.1\n")
        # banner reader: accept, read the client's SSH banner, close
        let srv = newSocket(buffered = false)
        srv.setSockOpt(OptReuseAddr, true)
        srv.bindAddr(Port(0), "127.0.0.1")
        srv.listen()
        defer: srv.close()
        let srvPort = int(srv.getLocalAddr()[1])
        var proxy = sw.startWallProxy(pol, dir, port = 0,
          unixSockPath = dir / "proxy.sock")
        defer: sw.stopWallProxy(proxy)
        let port = $int(proxy.port)
        let shimDir = sb.installSshShim(dir, binPath())
        var fenceEnv = {"WALL_PROXY_PORT": port,
          "WALL_PROXY_SOCK": dir / "proxy.sock",
          "PATH": shimDir & ":" & getEnv("PATH")}.newStringTable
        # netns probe first: skip (don't fail) without userns+netns
        let probe = startProcess(binPath(), args = ["sandbox", "--policy",
          pol, "restrict", "--", "true"], env = fenceEnv,
          options = {poStdErrToStdOut})
        let probeOk = probe.waitForExit(15_000) == 0
        probe.close()
        if not probeOk:
          skip()
        else:
          # 1. allowed: the shim's tunnel must carry ssh's banner to
          # the reader on host loopback (proxy resolves/dials for us)
          let p1 = startProcess(binPath(), args = ["sandbox", "--policy",
            pol, "restrict", "--", "ssh", "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=6",
            "-p", $srvPort, "127.0.0.1"], env = fenceEnv,
            options = {poStdErrToStdOut})
          var afd: SocketHandle = SocketHandle(-1)
          var waited = 0
          while afd.int < 0 and waited < 10_000:
            var fds = [TPollfd(fd: srv.getFd().cint, events: POLLIN,
                               revents: 0)]
            doAssert posix.poll(addr fds[0], 1, 100) >= 0
            if fds[0].revents != 0:
              afd = posix.accept(srv.getFd(), nil, nil)
            waited += 100
          check afd.int >= 0
          var banner = ""
          if afd.int >= 0:
            var buf = newString(256)
            var bwait = 0
            while banner.len < 8 and bwait < 5_000:
              var rfds = [TPollfd(fd: afd.cint, events: POLLIN, revents: 0)]
              if posix.poll(addr rfds[0], 1, 100) <= 0 or
                  (rfds[0].revents and POLLIN) == 0:
                inc bwait, 100
                continue
              let n = posix.recv(afd, addr buf[0], 255, 0'i32)
              if n > 0: banner.add(buf[0 ..< n])
              if n <= 0: break
            discard posix.close(afd)  # EOF: ssh gives up fast
          check banner.startsWith("SSH-2.0-")
          discard p1.waitForExit(15_000)
          p1.close()
          # 2. denied: the proxy refuses the SOCKS5 request and ssh
          # dies without reaching anything
          let r2 = execCmdEx(binPath() & " sandbox --policy " &
            pol.quoteShell & " restrict -- ssh -o StrictHostKeyChecking=no" &
            " -o UserKnownHostsFile=/dev/null -o ConnectTimeout=6 " &
            "denied.example </dev/null", env = fenceEnv,
            options = {poStdErrToStdOut, poDaemon})
          check r2.exitCode != 0
          check "denied.example" in r2.output

when defined(posix):
  suite "default policy keeps git working":
    test "git runs under the built-in default (gitconfig readable)":
      # Community report: "the model says the sandbox blocks git". Root
      # cause: git treats EACCES on an existing ~/.gitconfig as fatal
      # ("unknown error occurred while reading the configuration files")
      # on every invocation, and the old default fenced all of $HOME.
      # The default now carries `readonly ~/.gitconfig`; this test runs
      # real git under the real default policy to keep it true. HOME is
      # redirected to a scratch dir OUTSIDE the project so both the
      # policy's `~` and git's $HOME resolve against a .gitconfig that
      # exists (the absent-file case never trips the bug) while staying
      # outside every writable root - which is also what the write-back
      # check below needs.
      if findExe("git") == "":
        skip()
      else:
        # Under getTempDir the scratch home would sit inside the
        # default's `allow /tmp` and nothing would be fenced; the real
        # home is the one place the default leaves closed apart from
        # its named rules. Dot-prefixed and removed in the defer.
        let base = getHomeDir() / (".3code-gitdef-" & $getCurrentProcessId())
        let home = base / "home"
        let proj = base / "proj"
        createDir(home)
        createDir(proj)
        defer: removeDir(base)
        writeFile(home / ".gitconfig", "[user]\n\tname = T\n\temail = t@t\n")
        let pol = proj / "policy"
        writeFile(pol, sb.defaultPolicyText())
        discard execCmdEx("git -C " & proj.quoteShell & " init -q")
        writeFile(proj / "f.txt", "hi")
        var env = newStringTable()
        for k, v in envPairs(): env[k] = v
        env["HOME"] = home
        # `allow *` is a host rule, so the box fences; skip where the
        # kernel cannot (same posture as the netns e2e above).
        let probe = startProcess(binPath(), args = ["sandbox", "--policy",
          pol, "restrict", "--", "true"], env = env,
          options = {poStdErrToStdOut}, workingDir = proj)
        let probeOk = probe.waitForExit(15_000) == 0
        probe.close()
        if not probeOk:
          skip()
        else:
          template sandboxed(args: string): tuple[output: string, exitCode: int] =
            execCmdEx(binPath() & " sandbox --policy " & pol.quoteShell &
              " restrict -- " & args, env = env, workingDir = proj,
              options = {poStdErrToStdOut})
          let r = sandboxed("git status -s")
          check r.exitCode == 0
          check "fatal" notin r.output
          check "Permission denied" notin r.output
          check "?? f.txt" in r.output
          # The config grant is read-only: a global-config write must
          # still be fenced (HOME is outside every writable root).
          let w = sandboxed("git config --global probe.x y")
          check w.exitCode != 0
          check ("denied" in w.output or "error" in w.output)
