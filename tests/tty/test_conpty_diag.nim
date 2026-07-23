import std/[os, unittest]
import tty_expect

suite "conpty diagnostic":
  test "cmd.exe produces output under ConPTY":
    let tty = newTtySession(getEnv("WINDIR") / "System32" / "cmd.exe",
                            args = ["/c", "echo hello"],
                            env = [(key: "PATH", val: getEnv("PATH"))])
    defer: tty.close()
    let got = tty.expect("hello", timeoutMs = 5000)
    echo "saw hello: ", got
    echo "exited: ", tty.exited, " code: ", tty.exitCode
    echo "raw: [", tty.cleanRaw(), "]"
