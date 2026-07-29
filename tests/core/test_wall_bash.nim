import std/[net, os, osproc, posix, strtabs, strutils, times, unittest]
import threecode/sandbox as sb
import sandwall/wall as sw

## Fenced-bash wiring: proxy env helper, per-run proxy lifecycle, and
## an end-to-end netns launch through `3code box`. POSIX only; the e2e
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
    check "127.0.0.1" in t["NO_PROXY"]
    check t["GIT_SSH_COMMAND"].contains("wall connect %h %p")
    check t["GIT_SSH_COMMAND"].contains("/x/3code")
    # user-set GIT_SSH_COMMAND wins
    let e2 = sb.wallEnv("/x/3code", "12345", "", "ssh -i /key")
    for (k, v) in e2: check k != "GIT_SSH_COMMAND"
    for (k, v) in e2: check k != "WALL_PROXY_SOCK"  # no sock on macOS shape

suite "wall proxy lifecycle":
  test "proxy starts on host rules, reloads on policy rewrite":
    let dir = getTempDir() / ("3code-wallcycle-" & $getCurrentProcessId())
    createDir(dir / ".3code")
    defer:
      sb.stopWall()
      removeDir(dir)
    writeFile(dir / ".3code" / "sandbox", "- /\n+\n+127.0.0.1\n")
    let polCopy = dir / "policy-copy"
    copyFile(dir / ".3code" / "sandbox", polCopy)
    sb.current = parseCascaded(readFile(polCopy),
      readFile(dir / ".3code" / "sandbox"), dir)
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
    writeFile(dir / ".3code" / "sandbox", "- /\n+\n+127.0.0.1\n+example.com\n")
    sb.syncWallProxyPolicy(dir)
    let after = readFile(polFile)
    check after != before
    check "example.com" in after
    sb.stopWall()
    check sb.wallProxyPort() == 0

when defined(linux):
  suite "fenced bash end to end":
    test "netns: direct egress dies, proxy tunnel works":
      # Probe netns support with a trivial fenced launch first; skip
      # (don't fail) on kernels/containers without userns+netns.
      let dir = getTempDir() / ("3code-walle2e-" & $getCurrentProcessId())
      createDir(dir)
      defer: removeDir(dir)
      let pol = dir / "policy"
      writeFile(pol, "- /\n+ " & dir & "\n+ " & getTempDir() & "\n+127.0.0.1\n")
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
      let probe = startProcess(binPath(), args = ["box", "--policy", pol,
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
        let r1 = execCmdEx(binPath() & " box --policy " & pol.quoteShell &
          " restrict -- sh -c " &
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
        let p2 = startProcess(binPath(), args = ["box", "--policy", pol,
          "restrict", "--", "sh", "-c",
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
        let r3 = execCmdEx(binPath() & " box --policy " & pol.quoteShell &
          " restrict -- sh -c " & script3 & " </dev/null", env = probeEnv,
          options = {poDaemon})
        check "403" in r3.output
