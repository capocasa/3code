discard """
  action: run
  disabled: "win"
"""
import std/[os, osproc, strutils, tempfiles, unittest]

suite "test runner contracts":
  test "aggregate failures and preserve literal file arguments":
    let dir = createTempDir("runner-", "")
    defer: removeDir(dir)
    let fake = dir / "testament"
    writeFile(fake, "#!/bin/sh\nprintf '%s\\n' \"$4\" >> \"$RUNNER_ARGS\"\n[ \"$4\" != fail ]\n")
    setFilePermissions(fake, {fpUserRead, fpUserWrite, fpUserExec})
    let oldPath = getEnv("PATH")
    putEnv("PATH", dir & PathSep & oldPath)
    putEnv("RUNNER_ARGS", dir / "args")
    defer:
      putEnv("PATH", oldPath)
      delEnv("RUNNER_ARGS")
    let unusual = "space ' ; literal.nim"
    let run = execCmdEx("sh tools/test_dispatch.sh files fail " & quoteShell(unusual))
    check run.exitCode != 0
    check readFile(dir / "args").splitLines()[0..1] == @["fail", unusual]
    check execCmdEx("sh tools/test_dispatch.sh categories fail pass").exitCode != 0
    check execCmdEx("sh tools/test_dispatch.sh files pass").exitCode == 0
    putEnv("PATH", dir)
    removeFile(fake)
    check execCmdEx("/bin/sh tools/test_dispatch.sh all").exitCode == 127

  test "portable elapsed parsing and tree ownership":
    let run = execCmdEx("""sh -c '
. tools/test_processes.sh
[ "$(etime_secs 08:09)" = 489 ] || exit 1
[ "$(etime_secs 2-03:08:09)" = 184089 ] || exit 2
sleep 60 & unrelated=$!
sh -c "sleep 60 & wait" & owned_root=$!
sleep 0.1
children=$(descendants "$owned_root")
[ -n "$children" ] || exit 3
kill_tree "$owned_root"
kill -0 "$unrelated" || exit 4
kill "$unrelated"
wait 2>/dev/null
exit 0
'""")
    check run.exitCode == 0
