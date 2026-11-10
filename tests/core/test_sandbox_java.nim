when defined(posix):
  import std/[os, osproc, streams, strutils, times, unittest]

  import sandwall/seatbelt

  ## Java under the sandbox (gh #64): the JVM's first startup call,
  ## os::get_temp_directory(), resolves _CS_DARWIN_USER_TEMP_DIR via
  ## confstr, which goes through the com.apple.bsd.dirhelper mach
  ## service - under the bare (deny default) that bootstrap lookup
  ## EPERMs and every `java` hangs on mach_msg before main. The
  ## profile now allows that one global name and tags the default deny
  ## with a `with message` so `log show` can attribute denies to
  ## 3code. Two legs: the profile contract (pure string assembly,
  ## buildProfile links on every POSIX host - sandwall's seatbelt
  ## module resolves sandbox_init lazily via dlsym, so compiling this
  ## test nowhere loads libSystem) and a JVM smoke that self-skips
  ## without a JDK, like the dotnet test self-skips without an SDK.

  const binName = "3code"
  proc binPath(): string = getCurrentDir() / binName

  var backendCache = -1

  proc sandboxBackendWorks(): bool =
    ## Landlock needs prctl(NO_NEW_PRIVS), which some container seccomp
    ## profiles deny outright (EPERM, seen on the arm64 CI image): there
    ## the restrict machinery cannot engage at all, and the smoke leg
    ## would fail on the machinery instead of the contract under test.
    if backendCache >= 0: return backendCache == 1
    backendCache =
      if execCmdEx(binPath().quoteShell & " sandbox restrict " &
          getTempDir().quoteShell & " -- true").exitCode == 0: 1 else: 0
    backendCache == 1

  suite "sandbox java":
    test "seatbelt profile allows the dirhelper lookup and tags the deny":
      let p = buildProfile(["/tmp"], [])
      check "(allow mach-lookup (global-name \"com.apple.bsd.dirhelper\"))" in p
      check "(deny default (with message \"sandbox_3code\"))" in p
      # scoping: no untagged deny default slipped back in - the whole
      # point of the message is that `log show` can pick 3code's
      # denies out of every other sandboxed process's
      check "(deny default)\n" notin p

    test "java -version runs under sandbox restrict":
      let java = findExe("java")
      if java.len == 0 or not sandboxBackendWorks():
        skip()
      else:
        let dir = getTempDir() / ("3code-java-" & $getCurrentProcessId())
        createDir(dir)
        defer: removeDir(dir)
        let p = startProcess(binPath(), args =
          @["sandbox", "restrict", dir, "--", java, "-version"],
          options = {poStdErrToStdOut}, workingDir = dir)
        # Bounded wait: the gh #64 failure mode is a hang on mach_msg
        # before main, and a regression must fail fast, not wedge the
        # suite (and CI) on the exact symptom under test.
        let deadline = epochTime() + 120.0
        while p.running() and epochTime() < deadline:
          sleep(250)
        if p.running():
          p.terminate()
          discard p.waitForExit()
          p.close()
          checkpoint("java -version hung under the sandbox (the gh #64 regression)")
          fail()
        else:
          let output = p.outputStream().readAll()
          let code = p.waitForExit()
          p.close()
          check code == 0
          check "version \"" in output
else:
  import std/unittest
  # Windows fences via a separate user, not seatbelt/landlock; the
  # seatbelt profile contract is POSIX-only there.
  suite "sandbox java":
    test "posix-only":
      skip()
