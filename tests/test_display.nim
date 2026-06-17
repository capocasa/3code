import std/[os, strutils, unittest]

import threecode/display
import threecode/util

proc captureAssistant(content: string): string =
  let path = getTempDir() / "threecode_test_display_" & $getCurrentProcessId()
  let f = open(path, fmWrite)
  defer:
    try: removeFile(path) except OSError: discard
  renderAssistantContent(content, f)
  f.flushFile
  close(f)
  readFile(path)

suite "display: assistant rendering":
  test "assistant reply text is bright white across lines":
    let rendered = captureAssistant("first\nsecond")
    check rendered.startsWith(AssistantTextStyle & "● " & Reset &
      AssistantTextStyle & "first")
    check AssistantTextStyle & "  second" in rendered
    check AssistantTextStyle & "  second" & Reset in rendered

  test "assistant style resumes after inline markdown resets":
    let rendered = captureAssistant("before **bold** after")
    check "\x1b[22m" & AssistantTextStyle & " after" in rendered
