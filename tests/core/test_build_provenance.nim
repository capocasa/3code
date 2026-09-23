discard """
  action: run
  timeout: 120
  disabled: "windows"
"""
import std/[os, osproc, strutils, unittest]
import stub_helpers

suite "incremental build provenance":
  test "out-of-tree probes resolve quoted dependency paths":
    let dir = getTempDir() / ("3code-dep-path-" & $getCurrentProcessId())
    createDir(dir)
    defer: removeDir(dir)
    let source = dir / "probe.nim"
    writeFile(source, "import unicodedb/widths\necho \"resolved\"\n")
    let run = execCmdEx("nim c -r --hints:off" & nimbleDepFlags() &
      " --out:" & quoteShell(dir / "probe") & " " & source.quoteShell)
    check run.exitCode == 0
    check "resolved" in run.output

  test "inputs, options, atomic failure, concurrent cold writers":
    let dir = getTempDir() / ("3code-build-" & $getCurrentProcessId())
    createDir(dir)
    defer: removeDir(dir)
    let source = dir / "probe.nim"
    let binary = dir / "probe"
    writeFile(dir / "input.txt", "one")
    writeFile(dir / "part.nim", "const part = \"include-one\"\n")
    writeFile(dir / "dep.nim", "const dep* = \"dep-one\"\n")
    writeFile(dir / "config.nims", "switch(\"d\", \"configured=cfg-one\")\n")
    writeFile(source, """
import dep
include part
const configured {.strdefine.} = "missing"
const option {.strdefine.} = "default"
const data = staticRead("input.txt")
echo data, " ", part, " ", dep.dep, " ", configured, " ", option
""")
    let cmd = "sh tests/tools/build_binary.sh " & quoteShell(binary) & " " &
      quoteShell(source) & " --hints:off"
    proc build(extra = "") =
      let run = execCmdEx(cmd & extra)
      doAssert run.exitCode == 0, run.output
    proc output(): string = execProcess(quoteShell(binary)).strip
    build()
    check output() == "one include-one dep-one cfg-one default"
    writeFile(dir / "input.txt", "two")
    writeFile(dir / "part.nim", "const part = \"include-two\"\n")
    writeFile(dir / "dep.nim", "const dep* = \"dep-two\"\n")
    writeFile(dir / "config.nims", "switch(\"d\", \"configured=cfg-two\")\n")
    build(" -d:option=changed")
    check output() == "two include-two dep-two cfg-two changed"
    build()
    check output() == "two include-two dep-two cfg-two default"
    let valid = readFile(source)
    writeFile(source, "this does not compile !")
    check execCmdEx(cmd).exitCode != 0
    check output() == "two include-two dep-two cfg-two default"
    check not dirExists(binary & ".build-lock")
    writeFile(source, valid)
    removeFile(binary)
    removeDir(binary & ".nimcache")
    let first = startProcess(cmd, options = {poEvalCommand, poParentStreams})
    let second = startProcess(cmd, options = {poEvalCommand, poParentStreams})
    check first.waitForExit() == 0
    check second.waitForExit() == 0
    first.close()
    second.close()
    check output() == "two include-two dep-two cfg-two default"
    check not fileExists(binary & ".pending")
    createDir(binary & ".build-lock")
    putEnv("THREECODE_BUILD_LOCK_TIMEOUT", "1")
    defer: delEnv("THREECODE_BUILD_LOCK_TIMEOUT")
    check execCmdEx(cmd).exitCode != 0
    check output() == "two include-two dep-two cfg-two default"
