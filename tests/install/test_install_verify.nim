discard """
  disabled: "win"
  ## POSIX-only: it drives `install/install.sh` through a real shell and
  ## a local HTTP server. The PowerShell installer carries the same
  ## THREECODE_RELEASE_BASE override and verification logic by symmetry.
"""
## The two-step installer's checksum discipline (goal item 3): the
## script downloads the archive, verifies it against the release's
## SHASUMS256.txt, and only then installs. Driven here against a local
## HTTP server standing in for the release channel:
##
##   * matching checksum      -> installs, "checksum verified"
##   * mismatched checksum    -> refuses, nothing lands in the install dir
##   * sums absent            -> refuses (THREECODE_ALLOW_UNVERIFIED=1
##                               installs with a warning)
import std/[net, os, osproc, strutils, unittest]

const Script = "install/install.sh"

type FakeReleases = ref object
  listener: Socket
  root: string          # dir the paths resolve against
  running: bool
  port: uint16

var serverThread: Thread[FakeReleases]

proc serve(r: FakeReleases) {.thread.} =
  {.cast(gcsafe).}:
    while r.running:
      var client: Socket
      try:
        r.listener.accept(client)
      except CatchableError:
        break
      try:
        var req = ""
        while true:
          let line = client.recvLine(timeout = 2000)
          if line.strip.len == 0: break
          if req.len == 0: req = line
        if not req.startsWith("GET "):
          # the shutdown wake-up connection: no request to answer
          try: client.close() except CatchableError: discard
          continue
        let path = req.split(' ')[^2]     # "GET /<asset> HTTP/1.1"
        let file = r.root / path[1 ..< path.len]
        if fileExists(file):
          let body = readFile(file)
          client.send("HTTP/1.1 200 OK\r\nContent-Length: " & $body.len &
                      "\r\nConnection: close\r\n\r\n" & body, flags = {})
        else:
          client.send("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n" &
                      "Connection: close\r\n\r\n", flags = {})
      except CatchableError:
        discard
      try: client.close() except CatchableError: discard

proc startFakeReleases(root: string): tuple[base: string, srv: FakeReleases] =
  createDir(root)
  let s = FakeReleases(listener: newSocket(), root: root, running: true)
  s.listener.setSockOpt(OptReuseAddr, true)
  s.listener.bindAddr(Port(0), "127.0.0.1")
  s.listener.listen()
  let (_, port) = s.listener.getLocalAddr()
  s.port = port.uint16
  createThread(serverThread, serve, s)
  result = ("http://127.0.0.1:" & $s.port & "/", s)

proc stopFakeReleases(s: FakeReleases) =
  s.running = false
  # Closing the listener does not wake a thread blocked in accept() on
  # Linux; a local throwaway connection does (the drained request 404s,
  # then the loop sees running == false and returns, so join completes).
  let wake = newSocket()
  try:
    wake.connect("127.0.0.1", Port(s.port))
  except CatchableError: discard
  wake.close()
  try: s.listener.close() except CatchableError: discard
  joinThread(serverThread)

proc fakeAsset(): string =
  ## A plausible archive: an executable named `3code` at the root.
  let dir = getTempDir() / ("3code_inst_fixture_" & $getCurrentProcessId())
  removeDir(dir)
  createDir(dir)
  writeFile(dir / "3code", "#!/bin/sh\necho fake-3code\n")
  let perms: set[FilePermission] = {fpUserExec, fpUserRead, fpUserWrite}
  setFilePermissions(dir / "3code", perms)
  let outPath = getTempDir() / ("3code_inst_asset_" & $getCurrentProcessId() &
                                ".tar.gz")
  discard execCmdEx("tar -C " & quoteShell(dir) & " -czf " &
                    quoteShell(outPath) & " 3code")
  removeDir(dir)
  outPath

proc runInstaller(base, home: string; extraEnv = ""): tuple[code: int,
                                                             outp: string] =
  let cmd = "THREECODE_RELEASE_BASE=" & quoteShell(base) &
            " THREECODE_INSTALL_DIR=" & quoteShell(home / "bin") &
            " HOME=" & quoteShell(home) &
            (if extraEnv.len > 0: " " & extraEnv else: "") &
            " sh " & quoteShell(getCurrentDir() / Script)
  let r = execCmdEx(cmd)
  (r.exitCode, r.output)

suite "installer checksum verification":
  test "matching SHASUMS256.txt installs after verifying":
    let root = getTempDir() / ("3code_inst_good_" & $getCurrentProcessId())
    removeDir(root)
    let (base, srv) = startFakeReleases(root)
    defer: stopFakeReleases(srv)
    let asset = fakeAsset()
    copyFile(asset, root / "3code-linux-amd64.tar.gz")
    discard execCmdEx("sha256sum " & quoteShell(root / "3code-linux-amd64.tar.gz") &
                      " | awk '{print $1 \"  3code-linux-amd64.tar.gz\"}' > " &
                      quoteShell(root / "SHASUMS256.txt"))
    let home = root / "home"
    createDir(home)
    let (code, outp) = runInstaller(base, home)
    checkpoint(outp)
    check code == 0
    check "checksum verified" in outp
    check fileExists(home / "bin" / "3code")

  test "mismatched checksum refuses to install":
    let root = getTempDir() / ("3code_inst_bad_" & $getCurrentProcessId())
    removeDir(root)
    let (base, srv) = startFakeReleases(root)
    defer: stopFakeReleases(srv)
    copyFile(fakeAsset(), root / "3code-linux-amd64.tar.gz")
    writeFile(root / "SHASUMS256.txt",
              "deadbeef  3code-linux-amd64.tar.gz\n")
    let home = root / "home"
    createDir(home)
    let (code, outp) = runInstaller(base, home)
    checkpoint(outp)
    check code != 0
    check "checksum mismatch" in outp
    check not fileExists(home / "bin" / "3code")

  test "missing sums refuse; THREECODE_ALLOW_UNVERIFIED=1 installs warned":
    let root = getTempDir() / ("3code_inst_none_" & $getCurrentProcessId())
    removeDir(root)
    let (base, srv) = startFakeReleases(root)
    defer: stopFakeReleases(srv)
    copyFile(fakeAsset(), root / "3code-linux-amd64.tar.gz")
    let home = root / "home"
    createDir(home)
    let (code, outp) = runInstaller(base, home)
    checkpoint(outp)
    check code != 0
    check "no SHASUMS256.txt published" in outp
    check not fileExists(home / "bin" / "3code")
    let (code2, outp2) = runInstaller(base, home,
                                      "THREECODE_ALLOW_UNVERIFIED=1")
    checkpoint(outp2)
    check code2 == 0
    check "installing unverified" in outp2
    check fileExists(home / "bin" / "3code")
