import std/[os, osproc, strutils, unittest]

const binName = when defined(windows): "3code.exe" else: "3code"

proc binPath(): string = getCurrentDir() / binName

proc run(args: openArray[string]): tuple[o: string, code: int] =
  let (outp, code) = execCmdEx(binPath() & " " & args.join(" "))
  return (outp.strip(), code)

suite "cli argument validation":
  test "unknown long option errors":
    let r = run(["--nope"])
    check r.code == 2
    check "unknown option: --nope" in r.o

  test "unknown short option errors":
    let r = run(["-Z"])
    check r.code == 2
    check "unknown option: -Z" in r.o

  test "positional arg with --resume errors":
    let r = run(["--resume=does-not-exist", "ignored text"])
    check r.code == 2
    check "unexpected argument" in r.o

  test "positional arg with --interactive errors":
    let r = run(["--interactive", "ignored text"])
    check r.code == 2
    check "unexpected argument" in r.o
