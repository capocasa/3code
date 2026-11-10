import std/[json, os, sequtils, strutils, times, unittest]
import threecode/[search, session, types]

suite "session names: record round-trip":
  ## The `:rename` label rides the session record's BODY of the `.3log`:
  ## a body carries spaces ("Feature xyz") where the space-split header
  ## args cannot, and the listing peek (`previewSession`) reads exactly
  ## this record. XDG is pointed at a temp root so the user's real
  ## sessions are never touched.
  var savedXdg = ""
  var tmpRoot = ""

  setup:
    savedXdg = getEnv("XDG_DATA_HOME")
    tmpRoot = getTempDir() / ("3code-test-name-" & $getCurrentProcessId() &
                              "-" & $epochTime().int64)
    createDir(tmpRoot)
    putEnv("XDG_DATA_HOME", tmpRoot)

  teardown:
    if savedXdg.len > 0: putEnv("XDG_DATA_HOME", savedXdg)
    else: putEnv("XDG_DATA_HOME", "")
    removeDir(tmpRoot)

  proc namedSession(ts, name: string): Session =
    Session(created: ts, profileName: "test", cwd: "/proj/N", name: name)

  proc msgs(): JsonNode =
    %*[{"role": "system", "content": "sys"},
       {"role": "user", "content": "hi"}]

  test "render writes the name as the session record's body":
    let text = renderSession(namedSession("20260401T120000", "Feature xyz"),
                             msgs())
    check text.startsWith("session 20260401T120000 profile=test cwd=/proj/N\n")
    check "  Feature xyz\n" in text

  test "unnamed sessions render exactly as before (header only)":
    let text = renderSession(namedSession("20260401T120000", ""), msgs())
    check text.startsWith("session 20260401T120000 profile=test cwd=/proj/N\n")
    check "\n  " notin text.splitLines[0 ..< 2].join("\n")  # no body under the header

  test "load restores the name; unnamed loads empty":
    let dir = sessionDir()
    createDir(dir)
    writeFile(dir / "20260401T120000.3log",
              renderSession(namedSession("20260401T120000", "Feature xyz"), msgs()))
    writeFile(dir / "20260402T120000.3log",
              renderSession(namedSession("20260402T120000", ""), msgs()))
    let (named, _) = loadSessionFile(dir / "20260401T120000.3log")
    check named.name == "Feature xyz"
    let (plain, _) = loadSessionFile(dir / "20260402T120000.3log")
    check plain.name == ""

  test "preview exposes the name without the message tree":
    let dir = sessionDir()
    createDir(dir)
    writeFile(dir / "20260401T120000.3log",
              renderSession(namedSession("20260401T120000", "Feature xyz"), msgs()))
    check previewSession(dir / "20260401T120000.3log").name == "Feature xyz"

  test "a rename is a normal save away (saveSession persists it)":
    let dir = sessionDir()
    createDir(dir)
    var s = namedSession("20260401T120000", "")
    s.savePath = dir / "20260401T120000.3log"
    saveSession(s, msgs())
    check previewSession(s.savePath).name == ""
    s.name = "Feature xyz"
    saveSession(s, msgs())
    check previewSession(s.savePath).name == "Feature xyz"
    let (reloaded, _) = loadSessionFile(s.savePath)
    check reloaded.name == "Feature xyz"

suite "session names: resolution":
  ## `resolveSessionPath` accepts a name in addition to ids; exact ids
  ## beat id prefixes, id prefixes beat names, ambiguity at any stage
  ## raises `SessionAmbiguous` listing the candidates.
  var savedXdg = ""
  var tmpRoot = ""

  setup:
    savedXdg = getEnv("XDG_DATA_HOME")
    tmpRoot = getTempDir() / ("3code-test-resolve-" & $getCurrentProcessId() &
                              "-" & $epochTime().int64)
    createDir(tmpRoot)
    putEnv("XDG_DATA_HOME", tmpRoot)

  teardown:
    if savedXdg.len > 0: putEnv("XDG_DATA_HOME", savedXdg)
    else: putEnv("XDG_DATA_HOME", "")
    removeDir(tmpRoot)

  proc seed(ts, name, cwd: string) =
    let dir = sessionDir()
    createDir(dir)
    writeFile(dir / (ts & SessionExt),
      renderSession(Session(created: ts, profileName: "test", cwd: cwd,
                            name: name),
        %*[{"role": "user", "content": "body of " & ts}]))
    appendSessionIndex(cwd, ts)

  const cwd = "/proj/R"
  const otherCwd = "/proj/S"

  test "exact id still resolves through the fast path":
    seed("20260401T120000", "Feature xyz", cwd)
    check resolveSessionPath("20260401T120000", cwd) ==
      sessionDir() / "20260401T120000.3log"

  test "a unique name resolves, case-insensitively":
    seed("20260401T120000", "Feature xyz", cwd)
    check sessionIdFromPath(resolveSessionPath("Feature xyz", cwd)) ==
      "20260401T120000"
    check sessionIdFromPath(resolveSessionPath("feature XYZ", cwd)) ==
      "20260401T120000"

  test "a unique name prefix resolves":
    seed("20260401T120000", "Feature xyz", cwd)
    check sessionIdFromPath(resolveSessionPath("Feature", cwd)) ==
      "20260401T120000"

  test "ambiguous name raises listing the candidates":
    seed("20260401T120000", "Feature xyz", cwd)
    seed("20260402T120000", "feature xyz", cwd)
    expect SessionAmbiguous:
      discard resolveSessionPath("Feature xyz", cwd)
    try:
      discard resolveSessionPath("Feature xyz", cwd)
      check false
    except SessionAmbiguous as e:
      check "20260401T120000" in e.msg
      check "20260402T120000" in e.msg

  test "ambiguous id prefix raises and wins over a name match":
    # `2026` prefixes both ids; a session named "2026 extra" must not be
    # picked just because the prefix stage is ambiguous.
    seed("20260401T120000", "", cwd)
    seed("20260402T120000", "", cwd)
    seed("20260403T120000", "2026 extra", cwd)
    expect SessionAmbiguous:
      discard resolveSessionPath("2026", cwd)

  test "unique id prefix beats a session named alike":
    # One id-prefix hit and one exact-name hit: the id stage wins.
    seed("20260401T120000", "", cwd)
    seed("20260402T120000", "20260401T120000", cwd)
    check sessionIdFromPath(resolveSessionPath("20260401T120000", cwd)) ==
      "20260401T120000"
    check sessionIdFromPath(resolveSessionPath("20260401", cwd)) ==
      "20260401T120000"

  test "ambiguous name prefix raises":
    seed("20260401T120000", "Feature xyz", cwd)
    seed("20260402T120000", "Feature abc", cwd)
    expect SessionAmbiguous:
      discard resolveSessionPath("Feature", cwd)

  test "name matching stays inside the cwd scope":
    seed("20260401T120000", "Feature xyz", cwd)
    seed("20260402T120000", "Feature xyz", otherCwd)
    # cwd-scoped: the other directory's same-named session is invisible.
    check sessionIdFromPath(resolveSessionPath("Feature xyz", cwd)) ==
      "20260401T120000"
    # Unscoped (cwd = ""), both match → ambiguous.
    expect SessionAmbiguous:
      discard resolveSessionPath("Feature xyz", "")

  test "an unnamed id-shape query still reports not found":
    seed("20260401T120000", "", cwd)
    check resolveSessionPath("n Such", cwd) == ""

suite "session names: search surfaces the name":
  test "mapString extracts the name from the record body":
    let m = mapString("session 20260401T120000 profile=p cwd=/w\n" &
                      "  Feature xyz\n\nuser\n  hello\n")
    check m.name == "Feature xyz"
  test "unnamed sessions map to an empty name":
    let m = mapString("session 20260401T120000 profile=p cwd=/w\n\nuser\n  hi\n")
    check m.name == ""
  test "find terms match the name like any content":
    let hits = searchSessions(@["/whatever/x.3log"], @["feature"])
    check hits.len == 0  # sanity: the list only ever reflects real files
    let dir = getTempDir() / ("3code-test-find-" & $getCurrentProcessId())
    createDir(dir)
    defer: removeDir(dir)
    let p = dir / "20260401T120000.3log"
    writeFile(p, "session 20260401T120000 profile=p cwd=/w\n" &
                 "  Feature xyz\n\nuser\n  unrelated body\n")
    let found = searchSessions(@[p], @["feature"])
    check found.len == 1
    check found[0].name == "Feature xyz"
    check found[0].score == 1
