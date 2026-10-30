when defined(posix):
  import std/[os, osproc, streams, strformat, strutils, unittest]
  import sandwall/seatbelt

  ## Java under the sandbox, after gh #64 (the warp report). The JVM's
  ## first startup call is os::get_temp_directory() -> confstr, which on
  ## macOS resolves through the com.apple.bsd.dirhelper mach service;
  ## under a bare (deny default) the bootstrap lookup EPERMed and every
  ## java process hung on a mach_msg before main. The default deny is
  ## also message-tagged now, so a deny in `log show` names 3code
  ## instead of hiding among every other sandboxed process on the box.
  ##
  ## Profile generation is pure string assembly and links on every
  ## POSIX host, so the profile contract is pinned everywhere; the java
  ## run is the issue's own scenario and self-skips without a JDK.

  const binName = "3code"
  proc binPath(): string = getCurrentDir() / binName

  proc runSandboxed(policy, workDir: string; cmd: openArray[string]):
      tuple[output: string, exitCode: int] =
    let p = startProcess(binPath(), args = @["sandbox", "--policy", policy,
      "restrict", "--"] & @cmd, options = {poStdErrToStdOut},
      workingDir = workDir)
    result.output = p.outputStream().readAll()
    result.exitCode = p.waitForExit()
    p.close()

  suite "sandbox java":
    test "seatbelt profile carries the dirhelper lookup and a tagged deny":
      let p = seatbelt.buildProfile(["/tmp"], [])
      # confstr(_CS_DARWIN_USER_TEMP_DIR) goes through dirhelper's mach
      # service; the JVM calls it before anything else. Scoped to the
      # one global name, never a bare mach-lookup allow.
      check "(allow mach-lookup (global-name \"com.apple.bsd.dirhelper\"))" in p
      check "(allow mach-lookup)\n" notin p
      # every default deny names its origin for `log show` debugging
      check p.startsWith(
        "(version 1)\n(deny default (with message \"sandbox_3code\"))\n")
      check "(deny default)\n" notin p

    test "java starts under the default-shaped sandbox policy":
      let java = findExe("java")
      if java.len == 0:
        skip()
      else:
        let dir = getTempDir() / ("3code-java-" & $getCurrentProcessId())
        createDir(dir)
        defer: removeDir(dir)
        # getTempDir, not a hardcoded /tmp: the JVM writes its hsperfdata
        # file there, and on macOS runners TMPDIR is /var/folders.
        let pol = dir / "policy"
        writeFile(pol, &"deny /\nallow {getTempDir()}\nallow {dir}\nallow *\n")
        let r = runSandboxed(pol, dir, [java, "-version"])
        check r.exitCode == 0
        check "Version" in r.output
        check "Operation not permitted" notin r.output
else:
  import std/unittest
  # Windows fences via a separate user, not seatbelt/landlock; the
  # JVM-lookup contract is POSIX-only there.
  suite "sandbox java":
    test "posix-only":
      skip()
