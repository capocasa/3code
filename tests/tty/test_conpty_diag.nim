import std/[os, unittest]
import tty_expect

suite "conpty diagnostic":
  test "stub binary produces prompt with test cwd":
    let stub = getCurrentDir() / "build" / "3code_stub" & (when defined(windows): ".exe" else: "")
    let root = getCurrentDir() / "testdata" / "output" / "tty" / ("diag_" & $getCurrentProcessId())
    if dirExists(root): removeDir(root)
    createDir(root); createDir(root / "run")
    let tty = newTtySession(stub,
        args = ["-x", "-i"],
        cwd = root / "run",
        env = [(key: "PATH", val: getEnv("PATH")),
               (key: "HOME", val: root),
               (key: "XDG_DATA_HOME", val: root / "data"),
               (key: "XDG_CONFIG_HOME", val: root / "xdg")])
    defer: tty.close()
    let got = tty.expect("\u276f", timeoutMs = 5000)
    echo "saw prompt: ", got
    echo "exited: ", tty.exited, " code: ", tty.exitCode
    echo "raw len: ", tty.raw.len
