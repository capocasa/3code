when defined(posix):
  import std/[os, osproc, posix, strutils, unittest]
  import threecode/sandbox as sb

  ## gh #68: /dev/stdin, /dev/stdout, /dev/stderr in the default
  ## policy. Model-built command lines reference the stdio aliases
  ## constantly (`tool > /dev/stdout`, `foo --infile /dev/stdin`), and
  ## they are just re-opens of the process's own descriptors - safe by
  ## construction. But when stdio is a tty, the alias resolves to the
  ## tty device (/dev/pts/*), which neither the policy nor the sandwall
  ## baseline grants: every such access died with EPERM. The default
  ## policy now allows the three aliases; the backends canonicalize
  ## rule paths at restrict time in the child, so the grant lands on
  ## whatever fd 0/1/2 actually are (the tty device), and the aliases
  ## keep working unchanged when stdio is a pipe, which the kernel
  ## never fenced. The pty leg reproduces the issue end to end through
  ## the real `3code sandbox` binary with stdio on a real tty.

  const binName = "3code"
  proc binPath(): string = getCurrentDir() / binName

  var backendCache = -1

  proc sandboxBackendWorks(): bool =
    ## Same probe as test_sandbox_dotnet: when the kernel cannot engage
    ## the restrict machinery at all (no Landlock, seccomp-blocked
    ## NO_NEW_PRIVS), both legs would fail on the machinery, not on the
    ## contract under test.
    if backendCache >= 0: return backendCache == 1
    let code = execCmdEx(binPath().quoteShell & " sandbox restrict " &
        getTempDir().quoteShell & " -- true").exitCode
    backendCache = if code == 0: 1 else: 0
    backendCache == 1

  # openpty and login_tty live in different headers across platforms
  # (glibc: <pty.h>/<utmp.h>, macOS: <util.h>); import each symbol from
  # its own header, mirroring tests/tty_expect.nim.
  proc openpty(masterFd, slaveFd: ptr cint; name: pointer; termp: pointer;
               winp: pointer): cint {.cdecl, importc: "openpty",
                                      header: (when defined(macosx): "<util.h>"
                                               else: "<pty.h>").}

  proc login_tty(fd: cint): cint {.cdecl, importc: "login_tty",
                                   header: (when defined(macosx): "<util.h>"
                                            else: "<utmp.h>").}

  proc argvArray(bin: string; args: openArray[string]): cstringArray =
    var argv = newSeq[string](args.len + 1)
    argv[0] = bin
    for i, arg in args:
      argv[i + 1] = arg
    allocCStringArray(argv)

  proc runOnPty(args: openArray[string]; feed: string):
      tuple[output: string, exitCode: int] =
    ## Run the 3code binary with all three stdio streams on a fresh pty
    ## slave (the controlling terminal, canonical mode), `feed` written
    ## to the master ahead of the child's first read, and collect what
    ## comes back on the master plus the exit status. This is the shape
    ## of a user running `3code sandbox restrict -- ...` from their
    ## terminal: the aliases resolve to the tty device, not to pipes.
    ##
    ## The child must not spawn Nim threads or GC before exec: fork() in
    ## a threaded parent gives the child a copy of a possibly locked
    ## heap; only raw posix calls run between fork and execv.
    var master, slave: cint
    doAssert openpty(addr master, addr slave, nil, nil, nil) == 0
    let pid = fork()
    if pid == 0:
      discard close(master)
      discard login_tty(slave)
      let argv = argvArray(binPath(), args)
      discard execv(binPath().cstring, argv)
      quit(127)
    discard close(slave)
    if feed.len > 0:
      var written = 0
      while written < feed.len:
        let n = write(master, feed[written].unsafeAddr, feed.len - written)
        if n <= 0: break
        written += n
    # Blocking read until the master hits EOF (every slave fd closed
    # once the child tree exits). The probe command cannot block: it
    # reads the pre-fed stdin line and writes a few bytes.
    result.output = ""
    while true:
      var buf: array[4096, char]
      let n = read(master, addr buf[0], 4096)
      if n <= 0: break
      result.output.add buf.toOpenArray(0, n - 1).join()
    var status: cint = 0
    discard waitpid(pid.Pid, status, 0)
    if (status and 0x7f) == 0:
      result.exitCode = (status shr 8) and 0xff
    else:
      result.exitCode = 128 + (status and 0x7f)
    discard close(master)

  suite "sandbox /dev/std* devices":
    test "default policy allows the stdio aliases":
      let s = parsePolicy(sb.defaultPolicyText(), "/proj")
      check s.checkPath("/dev/stdin") == akWritable
      check s.checkPath("/dev/stdout") == akWritable
      check s.checkPath("/dev/stderr") == akWritable
      # the aliases do not widen anything else in /dev
      check s.checkPath("/dev/sda") == akDeny
      check s.checkPath("/dev") == akDeny

    test "stdio aliases work on a tty through the real backend":
      if not sandboxBackendWorks():
        skip()
      else:
        let dir = getTempDir() / ("3code-devstd-" & $getCurrentProcessId())
        createDir(dir)
        defer: removeDir(dir)
        let pol = dir / "policy"
        writeFile(pol, sb.defaultPolicyText())
        # one access per device: write stdout, write stderr, and read
        # two bytes back off stdin (canonical mode: the feed's newline
        # completes the line). With the pre-fix default each of the
        # three re-opens hits the tty device and dies with EPERM.
        let r = runOnPty(
          ["sandbox", "--policy", pol, "restrict", "--", "sh", "-c",
           "echo out > /dev/stdout; echo err > /dev/stderr; " &
           "echo \"got:$(head -c 2 /dev/stdin)\" > /dev/stdout"],
          feed = "hi\n")
        check r.exitCode == 0
        check "out" in r.output
        check "err" in r.output
        check "got:hi" in r.output
        check "Permission denied" notin r.output
else:
  import std/unittest
  # No /dev device namespace on Windows; the AppContainer child's stdio
  # is named pipes the fence never touched.
  suite "sandbox /dev/std* devices":
    test "posix-only":
      skip()
