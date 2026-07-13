import std/[os, strutils, times, unittest]
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

import std/[json]
import threecode/[session, types]

suite "display: printSessionList cap":
  # `printSessionList` is the single shared view for `-l` and `:sessions`,
  # so capping it covers both surfaces. Seeds sessions in an isolated
  # XDG_DATA_HOME so the test never touches real state, then captures
  # stdout to assert the cap and truncation hint.
  var savedXdg = ""
  var tmpRoot = ""
  var dir = ""
  var cwd = "/tmp/3code-test-cap-dir"

  setup:
    savedXdg = getEnv("XDG_DATA_HOME")
    tmpRoot = getTempDir() / ("3code-test-cap-" & $getCurrentProcessId() &
                              "-" & $epochTime().int64)
    createDir(tmpRoot)
    putEnv("XDG_DATA_HOME", tmpRoot)
    dir = sessionDir()
    createDir(dir)

  teardown:
    if savedXdg.len > 0: putEnv("XDG_DATA_HOME", savedXdg)
    else: delEnv("XDG_DATA_HOME")
    if dirExists(tmpRoot): removeDir(tmpRoot)

  proc seedSession(stamp, body: string) =
    # Minimal valid .3log: a session header (so previewSession picks up the
    # cwd) + one user line. All sessions share `cwd` so
    # listSessionPathsForCwd returns every one.
    let sess = Session(created: stamp, profileName: "stub", cwd: cwd)
    let msgs = %*[{"role": "system", "content": "sys"},
                  {"role": "user", "content": body}]
    writeFile(dir / (stamp & SessionExt), renderSession(sess, msgs))
    # Mirror saveSession: index the new file under its cwd so
    # listSessionPathsForCwd (which reads the index, not the dir) finds it.
    appendSessionIndex(cwd, stamp)

  when not defined(windows):
    proc captureList(paths: seq[string]): string =
      # Mirror the `captureStdout` helper in test_streaming_view.nim: swap
      # the `stdout` var for a temp file around the call.
      let outPath = tmpRoot / "list_out.txt"
      let saved = stdout
      let f = open(outPath, fmWrite)
      stdout = f
      try:
        printSessionList(paths, "", showCwd = false)
      finally:
        stdout.flushFile
        stdout = saved
        close(f)
      result = readFile(outPath).strip(leading = false)

  when not defined(windows):
    test "caps at SessionListCap and shows truncation hint":
      for i in 0 ..< 25:
        seedSession("2026010" & (if i < 10: "0" & $i else: $i) & "T120000",
                    "session number " & $i)
      let paths = listSessionPathsForCwd(cwd)
      check paths.len == 25
      let listing = captureList(paths)
      # 25 sessions (indices 0..24), newest-first → the 20 shown are
      # indices 24..5. Index 5 is the last shown; index 4 is the first cut.
      check "202601024T120000" in listing  # newest
      check "202601005T120000" in listing  # 20th shown (last)
      check "202601004T120000" notin listing  # 21st (capped out)
      check "202601000T120000" notin listing  # oldest
      check "20 of 25" in listing           # truncation hint
      check "more in" in listing

    test "no hint when under the cap":
      for i in 0 ..< 3:
        seedSession("2026020" & $i & "T120000", "session " & $i)
      let paths = listSessionPathsForCwd(cwd)
      check paths.len == 3
      let listing = captureList(paths)
      check "of 3" notin listing  # no truncation hint

import threecode/types

suite "display: tool transcript body strips boundary blanks":
  # A tool item must not bring its own newlines into scrollback. Web
  # search/fetch output (and any other head/tail-truncated kind) can arrive
  # with leading or trailing blank lines; the formatter strips both ends so
  # only the single transcript separator owns the inter-item blank row.
  test "web_search strips leading and trailing blank lines":
    let act = Action(kind: akWebSearch, body: "query")
    let res = "\n\n1. Hit one\n\n2. Hit two\n\n\n"
    let bytes = toolTranscriptBytes(act, res, code = 0, idx = 1)
    check "1. Hit one" in bytes
    check "2. Hit two" in bytes
    # No blank-wrapped row should appear before the first real content line.
    let firstContent = bytes.find("1. Hit one")
    check firstContent > 0
    let bannerEnd = bytes.find("\x1b[0m\r\n") + "\x1b[0m\r\n".len
    check bannerEnd > 0
    let between = bytes[bannerEnd ..< firstContent]
    check between.strip().len > 0

  test "web_fetch strips leading blank lines":
    let act = Action(kind: akWebFetch, body: "https://example.test/x")
    let res = "\n\n\nPage body\nMore body\n\n"
    let bytes = toolTranscriptBytes(act, res, code = 0, idx = 1)
    check "Page body" in bytes
    check "More body" in bytes
    let firstContent = bytes.find("Page body")
    let bannerEnd = bytes.find("\x1b[0m\r\n") + "\x1b[0m\r\n".len
    let between = bytes[bannerEnd ..< firstContent]
    check between.strip().len > 0
