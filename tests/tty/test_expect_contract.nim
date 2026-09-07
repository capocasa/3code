discard """
  action: run
  disabled: "win"
"""

import std/unittest
import ../tty_expect

suite "PTY assertion failure contracts":
  test "readiness has a bounded failing case and quiet cap is not success":
    let s = newTtySession("/bin/sh", @["-c", "while :; do printf x; sleep 0.01; done"])
    defer: s.close()
    s.waitUntil(proc(s: TtySession): bool = s.raw.len > 0, timeoutMs = 1000)
    expect AssertionDefect:
      s.waitUntil(proc(s: TtySession): bool = false, timeoutMs = 30)
    expect AssertionDefect:
      s.waitForQuiet(quietMs = 100, capMs = 40)

  test "missing assertions fail even after child exit":
    let s = newTtySession("/bin/sh", ["-c", "printf present"])
    defer: s.close()
    s.expectExit(0)
    s.expect("present")
    expect AssertionDefect:
      s.expect("absent", timeoutMs = 30)
    expect AssertionDefect:
      s.expectOnScreen("absent", timeoutMs = 30)
    expect AssertionDefect:
      s.expectCount("absent", 1, timeoutMs = 30)
    expect AssertionDefect:
      s.expectNo("present", settleMs = 30)
    expect AssertionDefect:
      s.expectInHistory("absent", timeoutMs = 30)
    expect AssertionDefect:
      s.expectNewInHistory("present", before = s.countInHistory("present"), timeoutMs = 30)
    expect AssertionDefect:
      s.expectNeverInHistory("present")
    expect AssertionDefect:
      s.expectExit(1, timeoutMs = 30)
    expect AssertionDefect:
      s.expectAlive()
    expect AssertionDefect:
      s.expectTypedAtPrompt("absent", timeoutMs = 30)
    expect AssertionDefect:
      s.expectIdleCaret(timeoutMs = 30)

  test "live child deadline fails":
    let s = newTtySession("/bin/sh", ["-c", "sleep 10"])
    defer: s.close()
    expect AssertionDefect:
      s.expect("absent", timeoutMs = 30)
    expect AssertionDefect:
      s.expectExit(0, timeoutMs = 30)
