import std/[os, unittest]
import tty_expect

suite "conpty diagnostic":
  test "stub binary produces prompt under ConPTY":
    let stub = getCurrentDir() / "build" / "3code_stub" & (when defined(windows): ".exe" else: "")
    let tty = newTtySession(stub,
        args = ["-x", "-i"],
        env = [(key: "PATH", val: getEnv("PATH")),
               (key: "HOME", val: getCurrentDir())])
    defer: tty.close()
    # Give it a moment, then dump whatever we got.
    discard tty.waitForOutput(3000)
    echo "exited: ", tty.exited, " code: ", tty.exitCode
    echo "raw len: ", tty.raw.len
    echo "raw: [", tty.cleanRaw()[0 ..< min(500, tty.cleanRaw().len)], "]"
