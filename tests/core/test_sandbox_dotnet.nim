when defined(posix):
  import std/[os, osproc, posix, streams, strformat, strutils, unittest]

  ## Unix sockets under the sandbox, end to end through the real
  ## `3code sandbox` binary (gh #55): build tools bind AF_UNIX sockets
  ## under the writable paths - dotnet's diagnostic server and
  ## MSBuild's worker nodes in the temp dir, tsx/VS Code IPC in the
  ## project dir. Landlock always granted that (MAKE_SOCK rides the
  ## writable rule); seatbelt needed the profile grants that ship
  ## with sandwall 0.5.12, so both backends now answer the same. The
  ## python probe pins the contract on every POSIX host with python3;
  ## the dotnet build runs the issue's own scenario when an SDK is
  ## installed. Both self-skip when their tool is missing - CI
  ## runners without dotnet stay green.

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

  proc isSocket(path: string): bool =
    var st: Stat
    if posix.stat(path.cstring, st) != 0: return false
    (st.st_mode.Mode and Mode(S_IFMT)) == Mode(S_IFSOCK)

  suite "sandbox unix sockets":
    test "writable path grants bind, connect, and accept":
      let py = findExe("python3")
      if py.len == 0:
        skip()
      else:
        let dir = getTempDir() / ("3code-unixsock-" & $getCurrentProcessId())
        createDir(dir)
        defer: removeDir(dir)
        let pol = dir / "policy"
        writeFile(pol, &"deny /\nallow {dir}\nallow *\n")
        # One process, the three syscalls the fence must let through:
        # bind+listen on a socket in the writable dir, connect to it,
        # accept the connection. `allow *` mirrors the default
        # policy's open-network posture.
        let r = runSandboxed(pol, dir, [py, "-c", """
import socket, sys
p = sys.argv[1]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(p)
s.listen(1)
c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
c.connect(p)
a, _ = s.accept()
c.send(b'ping')
assert a.recv(4) == b'ping'
print('SOCKET-OK')
""", dir / "s.sock"])
        check r.exitCode == 0
        check "SOCKET-OK" in r.output
        # python exited without unlinking: the socket node the
        # sandbox let it create is still there
        check isSocket(dir / "s.sock")

    test "dotnet build runs under the sandbox recipe":
      # gh #55 verbatim: MSBuild worker nodes and the dotnet
      # diagnostic server bind sockets in the temp dir, and NuGet is
      # fatal on an unreadable config. The policy is the manual's
      # dotnet recipe (NuGet cache writable, NuGet config readable).
      let dn = findExe("dotnet")
      if dn.len == 0:
        skip()
      else:
        # target whatever major.minor the installed SDK is, so the
        # csproj builds on any runner that has dotnet at all
        let ver = execCmdEx(dn & " --version").output.strip
        var tfm = "net8.0"
        let mnp = ver.split('-')[0].split('.')
        if mnp.len >= 2 and mnp[0].len > 0 and mnp[0][0].isdigit:
          tfm = "net" & mnp[0] & "." & mnp[1]
        let dir = getTempDir() / ("3code-dotnet-" & $getCurrentProcessId())
        createDir(dir)
        defer: removeDir(dir)
        writeFile(dir / "app.csproj", &"""
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>{tfm}</TargetFramework>
  </PropertyGroup>
</Project>
""")
        writeFile(dir / "Program.cs", "System.Console.WriteLine(\"built\");\n")
        let pol = dir / "policy"
        # getTempDir, not a hardcoded /tmp: TMPDIR is where dotnet
        # binds its diagnostic and MSBuild node sockets, and on macOS
        # runners that is /var/folders, not /tmp.
        writeFile(pol, &"deny /\nallow {getTempDir()}\nallow {dir}\n" &
          "allow ~/.nuget/packages\nreadonly ~/.nuget/NuGet\nallow *\n")
        let r = runSandboxed(pol, dir, [dn, "build", "-nologo"])
        check r.exitCode == 0
        check "Build succeeded" in r.output
        check "Permission denied" notin r.output
else:
  import std/unittest
  # Windows fences via a separate user, not seatbelt/landlock; the
  # unix-socket contract is POSIX-only there.
  suite "sandbox unix sockets":
    test "posix-only":
      skip()
