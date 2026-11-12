import std/[algorithm, base64, json, os, osproc, sequtils, strutils, times, unittest]
import threecode/[api, images, session, types, util]

when defined(posix):
  from std/posix import geteuid

when defined(posix):
  import std/posix except Time
when defined(windows):
  import std/winlean

if paramCount() == 2 and paramStr(1) == "--allocate":
  putEnv("XDG_DATA_HOME", paramStr(2))
  for i in 0..<30: echo newSessionPath()
  quit(0)

# -----------------------------------------------------------------------
# Cross-process lock helpers. The compiled test binary doubles as the
# lock scenario worker (same self-exec pattern as --allocate above):
# each mode performs one lock operation against files passed in argv and
# reports through files, so the controller never guesses at scheduling.
# Every worker is bounded (stop file, or a hard sleep cap) so a lost
# controller cannot strand a hung child.
# -----------------------------------------------------------------------

when defined(posix):
  # LOCK_EX|LOCK_NB, bound here so the raw holder needs no session.nim
  # machinery: it replicates the create-before-publication window with
  # bare OS calls.
  proc cFlock(fd: cint; op: cint): cint {.importc: "flock",
    header: "<sys/file.h>".}
  const kLockEx = 2.cint
  const kLockNb = 4.cint

  proc inoOf(path: string): BiggestInt =
    var s: Stat
    if posix.stat(path.cstring, s) == 0: result = BiggestInt(s.st_ino)

proc rawHoldLock(path: string): bool =
  ## Take the OS-level exclusive lock on `path` without publishing any
  ## owner metadata: the file keeps whatever text it had (or none).
  when defined(posix):
    let fd = posix.open(path.cstring, O_RDWR or O_CREAT, 0o600)
    if fd < 0: return false
    if cFlock(fd, kLockEx or kLockNb) != 0:
      discard posix.close(fd)
      return false
    result = true
  else:
    # GENERIC_READ|GENERIC_WRITE, FILE_SHARE_READ, OPEN_ALWAYS: the same
    # ownership-grade open the session lock uses, minus the metadata write.
    let h = winlean.createFileW(newWideCString(path), 0xC0000000'i32,
      1'i32, nil, 4'i32, 0x80'i32, 0)
    if h == winlean.INVALID_HANDLE_VALUE: return false
    result = true

proc waitForBarrier(path: string; seconds: float): bool =
  let deadline = epochTime() + seconds
  while epochTime() < deadline:
    if fileExists(path): return true
    sleep(20)
  fileExists(path)

proc spawnLockWorker(args: varargs[string]): Process =
  startProcess(getAppFilename(), args = @args, options = {poStdErrToStdOut})

proc hardKill(p: Process) =
  when defined(posix):
    discard posix.kill(Pid(p.processID()), SIGKILL)
  else:
    p.terminate()
  discard p.waitForExit(10000)
  p.close()

proc spawnDeadPid(): int =
  let sleepCmd = when defined(windows): "cmd /c exit 0" else: "true"
  var p = startProcess(sleepCmd, options = {poEvalCommand})
  result = p.processID()
  discard p.waitForExit()
  p.close()

if paramCount() == 2 and paramStr(1) == "--locksleep":
  sleep(60000)   # hard cap; the controller normally kills us sooner
  quit(0)

if paramCount() == 4 and paramStr(1) == "--lockhold":
  acquireSessionLock(paramStr(2))
  writeFile(paramStr(3), "1")
  let stopDeadline = epochTime() + 20
  while epochTime() < stopDeadline and not fileExists(paramStr(4)):
    sleep(25)
  releaseSessionLock(paramStr(2))
  quit(0)

if paramCount() == 4 and paramStr(1) == "--lockrawhold":
  # Map the session path to its lock file exactly as a contender will, so
  # the raw OS lock lands on the file the lock machinery uses.
  if not rawHoldLock(sessionLockPathFor(paramStr(2))): quit(3)
  writeFile(paramStr(3), "1")
  let stopDeadline = epochTime() + 20
  while epochTime() < stopDeadline and not fileExists(paramStr(4)):
    sleep(25)
  quit(0)

if paramCount() == 3 and paramStr(1) == "--locktry":
  # Rendezvous: contenders all reach the start line before any one tries,
  # and a winner keeps holding until told, so every contender decides
  # against a real holder instead of a released lock.
  writeFile(paramStr(3) & ".started", "1")
  let startDeadline = epochTime() + 10
  while epochTime() < startDeadline and not fileExists(paramStr(3) & ".go"):
    sleep(20)
  try:
    acquireSessionLock(paramStr(2))
    writeFile(paramStr(3), "owned:" & $getCurrentProcessId())
    let holdDeadline = epochTime() + 15
    while epochTime() < holdDeadline and not fileExists(paramStr(3) & ".done"):
      sleep(20)
    releaseSessionLock(paramStr(2))
  except SessionLocked:
    writeFile(paramStr(3), "refused")
  quit(0)

if paramCount() == 4 and paramStr(1) == "--lockspawnexit":
  # Acquire, spawn a tool-like grandchild that execs (closing inherited
  # lock fds), then exit without releasing: the grandchild is the probe
  # for whether the fd leaked across exec.
  acquireSessionLock(paramStr(2))
  let grand = spawnLockWorker("--locksleep", paramStr(4))
  discard waitForBarrier(paramStr(4), 10)   # grandchild execed
  writeFile(paramStr(3), $grand.processID())
  quit(0)

if paramCount() == 5 and paramStr(1) == "--dirlockhold":
  acquireDirLock(paramStr(2), paramStr(3))
  writeFile(paramStr(4), "1")
  while epochTime() < epochTime() + 20 and not fileExists(paramStr(5)):
    sleep(25)
  releaseActiveDirLock()
  quit(0)

if paramCount() == 3 and paramStr(1) == "--dirprobe":
  writeFile(paramStr(3), probeDirLockHeld(paramStr(2)))
  quit(0)

if paramCount() == 3 and paramStr(1) == "--dirlocktry":
  try:
    acquireDirLock(paramStr(2))
    writeFile(paramStr(3), "owned:" & $getCurrentProcessId())
    releaseActiveDirLock()
  except DirLocked:
    writeFile(paramStr(3), "refused")
  quit(0)

suite "session: atomic allocation":
  test "concurrent same and independent roots preserve identities and first save":
    let root = getTempDir() / ("3code-allocation-" & $getCurrentProcessId())
    createDir(root)
    defer: removeDir(root)
    var workers: seq[Process]
    for suffix in ["a", "a", "b", "b"]:
      workers.add startProcess(getAppFilename(), args = @["--allocate", root / suffix],
        options = {poStdErrToStdOut})
    var paths: seq[string]
    for worker in workers:
      let (output, code) = worker.readLines()
      check code == 0
      paths.add output
      worker.close()
    check paths.len == 120
    check paths.deduplicate.len == paths.len
    for path in paths:
      check fileExists(path)
      check getFileSize(path) == 0
    let oldData = getEnv("XDG_DATA_HOME")
    putEnv("XDG_DATA_HOME", root / "a")
    defer: putEnv("XDG_DATA_HOME", oldData)
    let s = Session(savePath: paths[0], cwd: root / "project")
    check currentDraftPath(s) == pendingDraftPathFor(s.cwd)
    saveSession(s, %*[])
    check currentDraftPath(s) == draftPathFor(s.savePath)
    check s.savePath in listSessionPathsForCwd(s.cwd)

  test "lock identity separates roots and resolves symlink aliases":
    let root = getTempDir() / ("3code-identity-" & $getCurrentProcessId())
    createDir(root / "a")
    createDir(root / "b")
    defer: removeDir(root)
    let a = root / "a" / "same.3log"
    let b = root / "b" / "same.3log"
    writeFile(a, "")
    writeFile(b, "")
    check sessionLockPathFor(a) != sessionLockPathFor(b)
    when defined(posix):
      createSymlink(root / "a", root / "alias")
      check sessionLockPathFor(a) == sessionLockPathFor(root / "alias" / "same.3log")
      check sessionLockPathFor(root / "a" / "new.3log") ==
        sessionLockPathFor(root / "alias" / "new.3log")

suite "session: mangleCwd":
  test "renders the common path readably":
    check mangleCwd("/home/carlo/p/3code/myworktree") == "home_carlo_p_3code_myworktree"

  test "keeps underscore cwds distinct from separator cwds":
    # The whole point of the doubling escape: these must not collide.
    check mangleCwd("/home/carlo_p") == "home_carlo__p"
    check mangleCwd("/home/carlo/p") == "home_carlo_p"
    check mangleCwd("/home/carlo_p") != mangleCwd("/home/carlo/p")

  test "doubled underscore stays doubled":
    # An original `__` becomes `____` — still invertible, still distinct.
    check mangleCwd("/a__b") == "a____b"

  test "collapses root and empty to a stable name":
    check mangleCwd("/") == "root"
    check mangleCwd("") == "root"

  test "normalizes backslashes to forward slashes":
    check mangleCwd("\\home\\carlo") == mangleCwd("/home/carlo")

  test "does not prefix a leading separator into the name":
    check not mangleCwd("/a/b").startsWith("_")

  test "caps long paths at a filename-safe length without collisions":
    # Deep tmpdir chains (macOS CI fixtures) once produced 260+ char lock
    # names: ENAMETOOLONG on every dir-lock write. The cap keeps a
    # readable head; the digest of the full name keeps distinct paths
    # distinct, including when they differ only past the cut.
    let deepA = "/tmp" & repeat("/3code_libtest_fixture_6997/tmp", 12)
    let deepB = "/tmp" & repeat("/3code_libtest_fixture_6997/tmp", 11) &
      "/3code_libtest_fixture_7000/tmp"
    let a = mangleCwd(deepA)
    let b = mangleCwd(deepB)
    check a.len == util.MangledNameCap
    check b.len == util.MangledNameCap
    check a != b
    check a == mangleCwd(deepA)   # deterministic across calls

suite "session: cwd index":
  var indexDir: string

  setup:
    indexDir = getTempDir() / ("3code-test-index-" & $epochTime().int64)
    removeDir(indexDir)

  teardown:
    removeDir(indexDir)

  test "indexIdsAt returns ids latest-first (append order reversed)":
    appendIndexAt(indexDir, "/home/carlo", "20250101T120000")
    appendIndexAt(indexDir, "/home/carlo", "20250102T120000")
    appendIndexAt(indexDir, "/home/carlo", "20250103T120000")
    check indexIdsAt(indexDir, "/home/carlo") == @[
      "20250103T120000", "20250102T120000", "20250101T120000"]

  test "one index file per cwd (distinct cwds stay separate)":
    appendIndexAt(indexDir, "/home/carlo/p", "aaa")
    appendIndexAt(indexDir, "/home/carlo_p", "bbb")
    check indexIdsAt(indexDir, "/home/carlo/p") == @["aaa"]
    check indexIdsAt(indexDir, "/home/carlo_p") == @["bbb"]

  test "blank lines in the index are skipped":
    let path = indexPathAt(indexDir, "/x")
    createDir(indexDir)
    writeFile(path, "one\n\n  \ntwo\n")
    check indexIdsAt(indexDir, "/x") == @["two", "one"]

  test "indexIdsAt is empty for a cwd with no index":
    check indexIdsAt(indexDir, "/never-saved").len == 0

suite "session: save → index → resume-latest integration":
  ## End-to-end check of the real save/index/resolve path. Uses a temp dir
  ## for the data root via XDG_DATA_HOME so we never touch the user's real
  ## sessions. The temp dir is created once per test and removed by name in
  ## teardown (never the real data root).
  var xdgBefore: string
  var tmpRoot: string
  var seed = 0

  setup:
    xdgBefore = getEnv("XDG_DATA_HOME")
    inc seed
    tmpRoot = getTempDir() / ("3code-test-e2e-" & $epochTime().int64 & "-" & $seed)
    putEnv("XDG_DATA_HOME", tmpRoot)

  teardown:
    if xdgBefore.len > 0: putEnv("XDG_DATA_HOME", xdgBefore)
    else: putEnv("XDG_DATA_HOME", "")
    removeDir(tmpRoot)

  proc makeSession(cwd, ts: string): Session =
    result = Session(created: ts, profileName: "test", cwd: cwd)
    result.savePath = sessionDir() / (ts & SessionExt)

  test "saveSession registers the session under its cwd":
    let msgs = %*[{"role": "system", "content": "sys"},
                  {"role": "user", "content": "hi"}]
    saveSession(makeSession("/proj/A", "20250101T100000"), msgs)
    check listSessionPathsForCwd("/proj/A").len == 1
    check sessionIdFromPath(listSessionPathsForCwd("/proj/A")[0]) == "20250101T100000"

  test "resume-latest picks the newest for the cwd, ignoring other cwds":
    let msgs = %*[{"role": "system", "content": "sys"},
                  {"role": "user", "content": "hi"}]
    saveSession(makeSession("/proj/A", "20250101T100000"), msgs)
    saveSession(makeSession("/proj/A", "20250102T100000"), msgs)
    saveSession(makeSession("/proj/B", "20250103T100000"), msgs)
    check sessionIdFromPath(resolveSessionPath("", "/proj/A")) == "20250102T100000"
    check sessionIdFromPath(resolveSessionPath("", "/proj/B")) == "20250103T100000"
    # The proj/B session must NOT leak into proj/A's list.
    let aIds = listSessionPathsForCwd("/proj/A").mapIt(sessionIdFromPath(it))
    check "20250103T100000" notin aIds

  test "re-saving an existing session does not add a duplicate index line":
    let msgs = %*[{"role": "system", "content": "sys"},
                  {"role": "user", "content": "hi"}]
    let s = makeSession("/proj/A", "20250101T100000")
    saveSession(s, msgs)
    saveSession(s, msgs)   # re-save: file now exists → not first save
    check listSessionPathsForCwd("/proj/A").len == 1

  when defined(posix):
    test "session file is only owner-readable (pasted secrets)":
      let msgs = %*[{"role": "user", "content": "hunter2"}]
      saveSession(makeSession("/proj/P", "20250101T110000"), msgs)
      let saved = sessionDir() / ("20250101T110000" & SessionExt)
      check getFilePermissions(saved) == {fpUserRead, fpUserWrite}

suite "session: private transcript directory":
  ## Private-mode sessions persist under `sessions-private/`, never in the
  ## plain directory, and the move into it is one-way. Same XDG isolation
  ## as the integration suite above.
  var
    xdgBefore: string
    tmpRoot: string
    savedMode = false
    seed = 0

  setup:
    savedMode = privateMode
    privateMode = false
    xdgBefore = getEnv("XDG_DATA_HOME")
    inc seed
    tmpRoot = getTempDir() / ("3code-test-priv-" & $epochTime().int64 & "-" & $seed)
    putEnv("XDG_DATA_HOME", tmpRoot)

  teardown:
    privateMode = savedMode
    if xdgBefore.len > 0: putEnv("XDG_DATA_HOME", xdgBefore)
    else: putEnv("XDG_DATA_HOME", "")
    removeDir(tmpRoot)

  test "allocation and image dir follow the mode":
    let plain = newSessionPath()
    check plain.startsWith(sessionDir())
    check sessionImageDir(plain) ==
      sessionDir() / (sessionIdFromPath(plain) & ".img")
    privateMode = true
    let priv = newSessionPath()
    check isPrivateSessionPath(priv)
    check sessionImageDir(priv) ==
      privateSessionDir() / (sessionIdFromPath(priv) & ".img")

  test "private saves index, list, and resolve like plain ones":
    privateMode = true
    var s = Session(created: "20260101T000000", profileName: "test", cwd: "/proj/P")
    s.savePath = newSessionPath()
    saveSession(s, %*[{"role": "system", "content": "sys"},
                      {"role": "user", "content": "hi"}])
    check isPrivateSessionPath(listSessionPathsForCwd("/proj/P")[0])
    let back = resolveSessionPath(sessionIdFromPath(s.savePath))
    check back.len > 0
    check isPrivateSessionPath(back)
    check s.savePath in listSessionPaths()

  test "adoptPrivateTranscriptDir moves a plain session, never back out":
    var s = Session(created: "20260101T000000", profileName: "test", cwd: "/proj/P")
    s.savePath = newSessionPath()   # mode off in setup: plain reservation
    check not adoptPrivateTranscriptDir(s)   # mode off: stays put
    let oldPath = s.savePath
    privateMode = true
    check adoptPrivateTranscriptDir(s)
    check isPrivateSessionPath(s.savePath)
    check not fileExists(oldPath)   # empty reservation dropped, not stranded
    check not adoptPrivateTranscriptDir(s)   # already private: idempotent
    var custom = Session(savePath: tmpRoot / "custom.3log")
    writeFile(custom.savePath, "")
    check not adoptPrivateTranscriptDir(custom)   # -s target: user's choice
    check custom.savePath == tmpRoot / "custom.3log"
    # The conversation keeps saving into the private dir after the move.
    saveSession(s, %*[{"role": "user", "content": "kept"}])
    check readFile(s.savePath).contains("kept")
    releaseSessionLock(s.savePath)   # later suites assert on the lock state

suite "session: usageFromJson":
  test "parses all fields":
    let j = %*{"promptTokens": 100, "completionTokens": 50,
               "totalTokens": 150, "cachedTokens": 30}
    let u = usageFromJson(j)
    check u.promptTokens == 100
    check u.completionTokens == 50
    check u.totalTokens == 150
    check u.cachedTokens == 30

  test "returns zeros for nil":
    let u = usageFromJson(nil)
    check u.promptTokens == 0
    check u.totalTokens == 0

suite "session: firstUserMessage":
  test "extracts first user message, strips preamble":
    let msgs = %*[
      {"role": "system", "content": "You are helpful."},
      {"role": "user", "content": "<session_context>\ncwd: /tmp\n</session_context>\n\nHello"},
      {"role": "assistant", "content": "Hi"},
      {"role": "user", "content": "Bye"}
    ]
    check firstUserMessage(msgs) == "Hello"

  test "returns empty for empty array":
    check firstUserMessage(newJArray()) == ""

suite "session: renderSession → loadSessionFile round-trip":
  var tmp: string

  setup:
    tmp = getTempDir() / "3code-test-session.3log"

  teardown:
    if fileExists(tmp): removeFile(tmp)

  proc roundTrip(sess: Session, msgs: JsonNode): (Session, JsonNode) =
    let text = renderSession(sess, msgs)
    writeFile(tmp, text)
    loadSessionFile(tmp)

  test "round-trips a simple user/assistant conversation":
    let sess = Session(created: "20250101T120000", profileName: "test",
                       cwd: "/tmp")
    let msgs = %*[
      {"role": "system", "content": "You are helpful."},
      {"role": "user", "content": "Hello"},
      {"role": "assistant", "content": "Hi there"}
    ]
    let (ls, lm) = roundTrip(sess, msgs)
    check ls.created == "20250101T120000"
    check ls.profileName == "test"
    check ls.cwd == "/tmp"
    # System is backfilled by loader
    check lm.len == 3
    check lm[0]["role"].getStr == "system"
    check lm[1]["role"].getStr == "user"
    check lm[1]["content"].getStr == "Hello"
    check lm[2]["role"].getStr == "assistant"
    check lm[2]["content"].getStr == "Hi there"

  test "round-trips assistant with tool_calls":
    let sess = Session(created: "20250101T120000", profileName: "test",
                       cwd: "/tmp")
    let msgs = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": "run ls"},
      {"role": "assistant", "content": "",
       "tool_calls": [{"id": "call_1", "type": "function",
                        "function": {"name": "bash",
                                     "arguments": "{\"command\": \"ls -la\"}"}}]},
      {"role": "tool", "tool_call_id": "call_1", "content": "file.txt"}
    ]
    let (ls, lm) = roundTrip(sess, msgs)
    check lm.len == 4
    check lm[0]["role"].getStr == "system"
    check lm[1]["role"].getStr == "user"
    # assistant with tool_calls
    let a = lm[2]
    check a["role"].getStr == "assistant"
    let tcs = a["tool_calls"]
    check tcs.len == 1
    check tcs[0]["function"]["name"].getStr == "bash"
    check "ls -la" in tcs[0]["function"]["arguments"].getStr
    # tool result
    check lm[3]["role"].getStr == "tool"
    check lm[3]["content"].getStr == "file.txt"
    # toolLog should have one entry
    check ls.toolLog.len == 1

  test "round-trips agentSent flags on user and tool messages":
    # Harness-autosend markers (`agentSent`) must survive the .3log so a
    # resumed replay renders `»` items for the empty-reply steer and an
    # abort batch's unexecuted remainder instead of a user echo / tool
    # banner.
    let sess = Session(created: "20250101T120000", profileName: "test",
                       cwd: "/tmp")
    let msgs = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": "go"},
      {"role": "assistant", "content": "",
       "tool_calls": [{"id": "call_9", "type": "function",
                        "function": {"name": "bash",
                                     "arguments": "{\"command\": \"ls\"}"}}]},
      {"role": "tool", "tool_call_id": "call_9",
       "content": "Loop detected.", "agentSent": true},
      {"role": "user", "content": "Please provide your final answer now.",
       "agentSent": true},
      {"role": "user", "content": "Goal check: keep going.",
       "agentSent": true, "goalSent": true}
    ]
    let (_, lm) = roundTrip(sess, msgs)
    check lm.len == 6
    check not lm[1].hasKey("agentSent")          # plain user stays plain
    check lm[3]{"agentSent"}.getBool(false)       # flail note keeps the mark
    check lm[3]["content"].getStr == "Loop detected."
    check lm[4]{"agentSent"}.getBool(false)       # steer keeps the mark
    check lm[4]["role"].getStr == "user"          # wire role unchanged
    check lm[5]{"agentSent"}.getBool(false)       # goal autosend keeps both
    check lm[5]{"goalSent"}.getBool(false)        # marks (replays as `⚑`)

  test "round-trips flailNote and strips it from the rebuilt toolLog":
    # A flail-noted call executed: the wire content carries the note on
    # top of the real result (byte-for-byte on resume), `flailNote` rides
    # the `flail` record + `+flail` flag so replay renders the `»` item,
    # and the rebuilt toolLog keeps only the bare result so the tool
    # banner never shows the warning as output.
    let sess = Session(created: "20250101T120000", profileName: "test",
                       cwd: "/tmp")
    let note = "Loop detected: you are repeating tool calls."
    let msgs = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": "go"},
      {"role": "assistant", "content": "",
       "tool_calls": [{"id": "call_f", "type": "function",
                        "function": {"name": "bash",
                                     "arguments": "{\"command\": \"ls\"}"}}]},
      {"role": "tool", "tool_call_id": "call_f",
       "content": note & "\n\nfile.txt\n", "flailNote": note}
    ]
    let text = renderSession(sess, msgs)
    check "flail call_f" in text
    check "tool_result call_f exit=0 +flail" in text
    writeFile(tmp, text)
    let (ls, lm) = loadSessionFile(tmp)
    check lm[3]{"flailNote"}.getStr == note
    check lm[3]["content"].getStr == note & "\n\nfile.txt\n"
    check ls.toolLog.len == 1
    check ls.toolLog[0].output == "file.txt\n"

  test "round-trips write action":
    let sess = Session(created: "20250101T120000", profileName: "test",
                       cwd: "/tmp")
    let msgs = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": "write a file"},
      {"role": "assistant", "content": "",
       "tool_calls": [{"id": "call_w", "type": "function",
                        "function": {"name": "write",
                                     "arguments": "{\"path\": \"src/foo.nim\", \"body\": \"echo 1\\n\"}"}}]},
      {"role": "tool", "tool_call_id": "call_w", "content": "wrote 7 bytes"}
    ]
    let (_, lm) = roundTrip(sess, msgs)
    let args = parseJson(lm[2]["tool_calls"][0]["function"]["arguments"].getStr)
    check args["path"].getStr == "src/foo.nim"
    # The wire section preserves the body byte-exactly, trailing newline
    # included (the old human-readable codec stripped it).
    check args["body"].getStr == "echo 1\n"

  test "round-trips patch action":
    let sess = Session(created: "20250101T120000", profileName: "test",
                       cwd: "/tmp")
    let msgs = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": "patch it"},
      {"role": "assistant", "content": "",
       "tool_calls": [{"id": "call_p", "type": "function",
                        "function": {"name": "patch",
                                     "arguments": "{\"path\": \"a.nim\", \"edits\": [{\"search\": \"old\", \"replace\": \"new\"}]}"}}]},
      {"role": "tool", "tool_call_id": "call_p", "content": "patched 1 edit"}
    ]
    let (_, lm) = roundTrip(sess, msgs)
    let args = parseJson(lm[2]["tool_calls"][0]["function"]["arguments"].getStr)
    check args["path"].getStr == "a.nim"
    check args["edits"][0]["search"].getStr == "old"
    check args["edits"][0]["replace"].getStr == "new"

  test "round-trips usage/tokens":
    let sess = Session(created: "20250101T120000", profileName: "test",
                       cwd: "/tmp")
    let msgs = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": "hi"},
      {"role": "assistant", "content": "yo",
       "usage": {"promptTokens": 200, "completionTokens": 100,
                 "totalTokens": 300, "cachedTokens": 50, "elapsed": 5}}
    ]
    let (ls, _) = roundTrip(sess, msgs)
    check ls.usage.totalTokens == 300
    check ls.usage.promptTokens == 200
    check ls.usage.cachedTokens == 50

  test "round-trips reasoning_content":
    let sess = Session(created: "20250101T120000", profileName: "test",
                       cwd: "/tmp")
    let msgs = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": "think"},
      {"role": "assistant", "content": "answer",
       "reasoning_content": "thinking..."}
    ]
    let (_, lm) = roundTrip(sess, msgs)
    check lm[2]["content"].getStr == "answer"
    check lm[2]["reasoning_content"].getStr == "thinking..."

  test "round-trips empty assistant reply":
    let sess = Session(created: "20250101T120000", profileName: "test",
                       cwd: "/tmp")
    let msgs = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": "hi"},
      {"role": "assistant", "content": ""}
    ]
    let (ls, lm) = roundTrip(sess, msgs)
    check lm.len == 3
    check lm[2]["role"].getStr == "assistant"
    check lm[2]["content"].getStr == "empty reply - no content, no tool calls"

  test "round-trips empty assistant reply with finish_reason":
    # The provider's explanation for an empty turn must survive the .3log
    # so a resumed replay renders `empty reply: <reason>` instead of the
    # bare fallback.
    let sess = Session(created: "20250101T120000", profileName: "test",
                       cwd: "/tmp")
    let msgs = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": "hi"},
      {"role": "assistant", "content": "", "finish_reason": "length"}
    ]
    let (_, lm) = roundTrip(sess, msgs)
    check lm[2]["content"].getStr == EmptyReplyMsg
    check lm[2]["finish_reason"].getStr == "length"

  test "round-trips session_context / project_notes preamble":
    let sess = Session(created: "20250101T120000", profileName: "test",
                       cwd: "/tmp")
    let content = "<session_context>\ncwd: /tmp\n</session_context>\n\n<project_notes>\n# Notes\n</project_notes>\n\nactual message"
    let msgs = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": content}
    ]
    let (_, lm) = roundTrip(sess, msgs)
    check lm[1]["content"].getStr == content

  test "round-trips plan items (update_plan/todo tool)":
    let sess = Session(created: "20250101T120000", profileName: "test",
                       cwd: "/tmp")
    let msgs = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": "plan"},
      {"role": "assistant", "content": "",
       "tool_calls": [{"id": "call_plan", "type": "function",
                        "function": {"name": "update_plan",
                                     "arguments": "{\"items\": [{\"text\": \"step 1\", \"status\": \"completed\"}, {\"text\": \"step 2\", \"status\": \"pending\"}]}"}}]},
      {"role": "tool", "tool_call_id": "call_plan", "content": "plan updated"}
    ]
    let (ls, lm) = roundTrip(sess, msgs)
    let args = parseJson(lm[2]["tool_calls"][0]["function"]["arguments"].getStr)
    check args["items"].len == 2
    check args["items"][0]["text"].getStr == "step 1"
    check args["items"][0]["status"].getStr == "completed"
    check args["items"][1]["text"].getStr == "step 2"
    # plan should also be rebuilt on the session
    check ls.plan.len == 2

  test "round-trips web_search and web_fetch args":
    # Regression: these used to fall into the unknown-tool branch, so the
    # query/url was lost on resume and the replayed banner rendered as a
    # bare icon.
    let sess = Session(created: "20250101T120000", profileName: "test",
                       cwd: "/tmp")
    let msgs = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": "search"},
      {"role": "assistant", "content": "",
       "tool_calls": [
         {"id": "call_s", "type": "function",
          "function": {"name": "web_search",
                       "arguments": "{\"query\": \"terminal rendering\"}"}},
         {"id": "call_f", "type": "function",
          "function": {"name": "web_fetch",
                       "arguments": "{\"url\": \"https://example.test/x\"}"}}
       ]},
      {"role": "tool", "tool_call_id": "call_s", "content": "hit"},
      {"role": "tool", "tool_call_id": "call_f", "content": "page"}
    ]
    let (ls, lm) = roundTrip(sess, msgs)
    let sArgs = parseJson(lm[2]["tool_calls"][0]["function"]["arguments"].getStr)
    check sArgs["query"].getStr == "terminal rendering"
    let fArgs = parseJson(lm[2]["tool_calls"][1]["function"]["arguments"].getStr)
    check fArgs["url"].getStr == "https://example.test/x"
    check ls.toolLog.len == 2
    check ls.toolLog[0].banner == "terminal rendering"
    check ls.toolLog[1].banner == "https://example.test/x"

suite "session: resume wire parity":
  ## The resume path must re-send exactly what the live session sent.
  ## `callModel` transmits repairToolCallPairing(stripInternalFields(m)),
  ## so parity means that composition over the loaded array equals the
  ## composition over the saved array, byte for byte.
  var tmp: string

  setup:
    tmp = getTempDir() / ("3code-wire-parity-" & $getCurrentProcessId() & ".3log")

  teardown:
    if fileExists(tmp): removeFile(tmp)

  proc wireOf(msgs: JsonNode): string =
    ## Parity from the first user message on: the system prompt is
    ## constructed at resume from the profile + persisted catalog, never
    ## round-tripped through the file.
    let stripped = stripInternalFields(msgs)
    var tail = newJArray()
    for i in 1 ..< stripped.len: tail.add stripped[i]
    $repairToolCallPairing(tail)

  proc roundTrip(sess: Session, msgs: JsonNode): JsonNode =
    writeFile(tmp, renderSession(sess, msgs))
    loadSessionFile(tmp)[1]

  test "tool result trailing newline survives the round-trip":
    # Bash output always ends in a newline; the old codec dropped it,
    # so every resumed session's history differed by one byte per tool.
    let sess = Session(created: "t", profileName: "p", cwd: "/tmp")
    let msgs = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": "run"},
      {"role": "assistant", "content": "", "reasoning_content": "",
       "tool_calls": [{"id": "c1", "type": "function",
                        "function": {"name": "bash",
                                     "arguments": "{\"command\": \"echo hi\"}"}}]},
      {"role": "tool", "tool_call_id": "c1", "content": "hi\n"}
    ]
    let lm = roundTrip(sess, msgs)
    check lm[3]{"content"}.getStr == "hi\n"
    check wireOf(lm) == wireOf(msgs)

  test "bodies with trailing blank lines round-trip":
    let sess = Session(created: "t", profileName: "p", cwd: "/tmp")
    let msgs = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": "a\n\n\n"},
      {"role": "assistant", "content": "b\n"},
      {"role": "user", "content": "\n\n"},
      {"role": "assistant", "content": "done"}
    ]
    let lm = roundTrip(sess, msgs)
    for i in 1 ..< msgs.len:
      check lm[i]{"content"}.getStr == msgs[i]{"content"}.getStr

  test "tool_call wire JSON is preserved verbatim":
    # Key order, extra fields like `index`, and raw argument spacing are
    # the bytes the server sent; the loader must replay them exactly.
    let sess = Session(created: "t", profileName: "p", cwd: "/tmp")
    let verbatim = %*{"id": "c9", "index": 0, "type": "function",
                       "function": {"name": "bash",
                                    "arguments": "{\"command\": \"ls -la\"}"}}
    let msgs = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": "go"},
      {"role": "assistant", "content": "", "reasoning_content": "",
       "tool_calls": [verbatim]},
      {"role": "tool", "tool_call_id": "c9", "content": "out\n"}
    ]
    let lm = roundTrip(sess, msgs)
    check $lm[2]{"tool_calls"}[0] == $verbatim
    check wireOf(lm) == wireOf(msgs)

  test "preamble bytes round-trip without reflow":
    let sess = Session(created: "t", profileName: "p", cwd: "/tmp")
    let content = "<session_context>\ncwd: /tmp\ngit: main\n" &
      "</session_context>\n\n<project_notes>\n# Notes\n\nkeep\n" &
      "</project_notes>\n\nuser text here"
    let msgs = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": content}
    ]
    let lm = roundTrip(sess, msgs)
    check lm[1]{"content"}.getStr == content
    check wireOf(lm) == wireOf(msgs)

  test "dynamic prompt inputs persist; the prompt itself does not":
    let sess = Session(created: "t", profileName: "p", cwd: "/tmp",
      promptState: PromptState(identity: "[\"prov.m\"]",
                               skills: "- /skills/one.md"))
    let msgs = %*[
      {"role": "system", "content": "FULL BUILT PROMPT"},
      {"role": "user", "content": "hi"},
      {"role": "assistant", "content": "yo", "reasoning_content": ""}
    ]
    writeFile(tmp, renderSession(sess, msgs))
    let text = readFile(tmp)
    check "FULL BUILT PROMPT" notin text        # constructed, not stored
    check "- /skills/one.md" in text            # the dynamic part is
    check "prompt_identity=[\"prov.m\"]" in text
    let (ls, lm) = loadSessionFile(tmp)
    check ls.promptState.identity == "[\"prov.m\"]"
    check ls.promptState.skills == "- /skills/one.md"
    check ls.promptState.system == nil          # rebuild owns index 0
    check lm[0]{"role"}.getStr == "system"     # placeholder backfill
    check wireOf(lm) == wireOf(msgs)

  test "legacy verbatim system record loads but is never adopted":
    writeFile(tmp, """session 2025-01-01T00:00:00+00:00 profile=p cwd=/tmp prompt_identity=["x"]

system
  OLD VERBATIM PREFIX

user
  hi
""")
    let (ls, lm) = loadSessionFile(tmp)
    check lm[0]{"role"}.getStr == "system"
    check lm[0]{"content"}.getStr == "OLD VERBATIM PREFIX"
    check ls.promptState.identity == "[\"x\"]"
    # Resume reconstructs from the profile; the persisted body is not
    # seeded into PromptState as a keep-verbatim prefix.
    check ls.promptState.system == nil
    check ls.promptState.skills.len == 0

  test "empty reasoning_content key is present on resumed assistants":
    # Think-back families keep the field on the wire; the loader must set
    # it (empty) like the live transports do, not omit it.
    let sess = Session(created: "t", profileName: "p", cwd: "/tmp")
    let msgs = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": "hi"},
      {"role": "assistant", "content": "hello",
       "reasoning_content": ""}
    ]
    let lm = roundTrip(sess, msgs)
    check lm[2].contains("reasoning_content")
    check wireOf(lm) == wireOf(msgs)

  test "legacy log without stamps still loads":
    writeFile(tmp, """session 2025-01-01T00:00:00+00:00 profile=p cwd=/tmp

user
  old style

assistant
  reply
""")
    let (ls, lm) = loadSessionFile(tmp)
    check ls.promptState.identity.len == 0
    check lm[0]{"role"}.getStr == "system"
    check lm[1]{"content"}.getStr == "old style"

suite "session: sessionIdFromPath":
  test "strips .3log extension":
    check sessionIdFromPath("/some/dir/20250101T120000.3log") == "20250101T120000"

  test "returns full name when no extension":
    check sessionIdFromPath("/some/dir/my-session") == "my-session"

suite "session: session lock acquire/release":
  # Unique fake session per test so we never touch real sessions and tests
  # don't race each other.
  var tmpPath: string

  setup:
    tmpPath = getTempDir() / ("3code-test-lock-" & $epochTime().int64 & ".3log")

  teardown:
    # Releases everything this process owns; lock files are persistent,
    # so removing them afterwards is safe only because we no longer hold
    # them.
    releaseActiveSessionLock()
    if fileExists(tmpPath): removeFile(tmpPath)
    let lp = sessionLockPathFor(tmpPath)
    if fileExists(lp): removeFile(lp)

  test "acquire creates the lock file holding our pid":
    acquireSessionLock(tmpPath)
    let lp = sessionLockPathFor(tmpPath)
    check fileExists(lp)
    check readFile(lp).strip == $getCurrentProcessId()
    check activeSessionLockPath() == lp

  test "acquiring a held lock raises SessionLocked with guidance":
    acquireSessionLock(tmpPath)
    let lp = sessionLockPathFor(tmpPath)
    var msg = ""
    try:
      acquireSessionLock(tmpPath)
      fail()
    except SessionLocked as e:
      msg = e.msg
    # message names the session id, the lock file path, the owner pid,
    # and tells the user how to clear a stale lock
    check sessionIdFromPath(tmpPath) in msg
    check lp in msg
    check $getCurrentProcessId() in msg
    check "stale" in msg.toLowerAscii

  test "releaseSessionLock keeps the persistent file, emptied of owner text":
    acquireSessionLock(tmpPath)
    let lp = sessionLockPathFor(tmpPath)
    check fileExists(lp)
    releaseSessionLock(tmpPath)
    # The file stays: unlinking a released path would let a second
    # process lock a fresh inode while the first still owns the old one.
    # Owner metadata is erased so stale pid text never counts as a lock.
    check fileExists(lp)
    check readFile(lp) == ""
    check activeSessionLockPath() == ""
    # An emptied file is plain state, not a lock: immediately acquirable.
    acquireSessionLock(tmpPath)
    check activeSessionLockPath() == lp
    releaseSessionLock(tmpPath)

  test "releaseActiveSessionLock clears ownership, keeps the file":
    acquireSessionLock(tmpPath)
    let lp = sessionLockPathFor(tmpPath)
    check activeSessionLockPath() == lp
    releaseActiveSessionLock()
    check fileExists(lp)
    check readFile(lp) == ""
    check activeSessionLockPath() == ""

  test "release of a never-held lock is a no-op":
    releaseSessionLock(tmpPath)
    check activeSessionLockPath() == ""
    # It must not disturb a lock this process legitimately holds.
    let other = tmpPath & ".other"
    acquireSessionLock(other)
    releaseSessionLock(tmpPath)
    check activeSessionLockPath() == sessionLockPathFor(other)
    releaseSessionLock(other)

  test "repeated release is safe":
    acquireSessionLock(tmpPath)
    releaseSessionLock(tmpPath)
    releaseSessionLock(tmpPath)
    check activeSessionLockPath() == ""

  test "acquire on empty path is a no-op":
    acquireSessionLock("")
    check activeSessionLockPath() == ""

  # ---- stale-lock recovery (cross-platform) -------------------------------
  # A lock left behind by a crashed/killed 3code must be reclaimed and
  # acquisition must succeed, not refuse.

  test "stale lock whose owner pid is dead is reclaimed in place and acquired":
    # Produce a genuinely-dead pid: spawn a trivial child, wait for it to exit,
    # then write its (now-reaped) pid into the lock as if a 3code had died.
    let deadPid = spawnDeadPid()
    # Sanity: the pid we recorded really is dead. (Extremely unlikely to have
    # been reused instantly, but guard the test's own assumption.)
    check deadPid != getCurrentProcessId()

    let lp = sessionLockPathFor(tmpPath)
    createDir(parentDir(lp))
    writeFile(lp, $deadPid)
    check fileExists(lp)
    when defined(posix):
      let inoBefore = inoOf(lp)

    # Acquisition should take ownership and publish our pid in place,
    # without deleting the file.
    acquireSessionLock(tmpPath)
    check activeSessionLockPath() == lp
    check readFile(lp).strip == $getCurrentProcessId()
    when defined(posix):
      check inoOf(lp) == inoBefore

  test "corrupt lock (non-numeric pid) is reclaimed and acquired":
    let lp = sessionLockPathFor(tmpPath)
    createDir(parentDir(lp))
    writeFile(lp, "not-a-pid")
    check fileExists(lp)
    # Must not crash; treat unparseable pid as stale and move on.
    acquireSessionLock(tmpPath)
    check activeSessionLockPath() == lp
    check readFile(lp).strip == $getCurrentProcessId()

  test "empty lock file is reclaimed and acquired":
    let lp = sessionLockPathFor(tmpPath)
    createDir(parentDir(lp))
    writeFile(lp, "")
    check fileExists(lp)
    acquireSessionLock(tmpPath)
    check activeSessionLockPath() == lp
    check readFile(lp).strip == $getCurrentProcessId()

suite "session: directory lock acquire/release":

  teardown:
    # Releases everything this process owns; the persistent lock files are
    # then unowned and safe to remove.
    releaseActiveDirLock()
    let dld = dirLockDir()
    if dirExists(dld):
      for kind, path in walkDir(dld):
        if kind == pcFile and
            extractFilename(path).contains("test-dir-lock"):
          try: removeFile(path) except OSError: discard

  test "acquire creates the lock file holding our pid":
    let cwd = "/home/carlo/p/test-dir-lock"
    acquireDirLock(cwd)
    let lp = dirLockPathFor(cwd)
    check fileExists(lp)
    check readFile(lp).strip == $getCurrentProcessId()
    check activeDirLockPath() == lp

  test "probeDirLockHeld names a live holder without acquiring":
    let cwd = "/home/carlo/p/test-dir-lock-probe"
    # nothing held: no message, and no lock file created by the probe
    check probeDirLockHeld(cwd) == ""
    check not fileExists(dirLockPathFor(cwd))
    acquireDirLock(cwd, sessionDir() / ("20260101T000000" & SessionExt))
    let msg = probeDirLockHeld(cwd)
    check "already open" in msg
    check "session 20260101T000000" in msg
    check dirLockPathFor(cwd) in msg
    releaseActiveDirLock()
    # The persistent file remains but carries no owner text: not a lock.
    check fileExists(dirLockPathFor(cwd))
    check probeDirLockHeld(cwd) == ""

  test "acquiring a held lock raises DirLocked with guidance":
    let cwd = "/home/carlo/p/test-dir-lock-live"
    let sess = sessionDir() / ("20260101T000000" & SessionExt)
    acquireDirLock(cwd, sess)
    let lp = dirLockPathFor(cwd)
    var msg = ""
    try:
      acquireDirLock(cwd)
      fail()
    except DirLocked as e:
      msg = e.msg
    check cwd in msg
    check lp in msg
    check $getCurrentProcessId() in msg
    # second lock line names the holder's session id
    check readFile(lp).strip.splitLines.len == 2
    check "20260101T000000" in readFile(lp)
    check "session 20260101T000000" in msg
    check "stale" in msg.toLowerAscii

  test "updateActiveDirLockSession rewrites the session id line":
    let cwd = "/home/carlo/p/test-dir-lock-move"
    acquireDirLock(cwd, sessionDir() / ("20260101T000000" & SessionExt))
    updateActiveDirLockSession(sessionDir() / ("20260202T000000" & SessionExt))
    let lp = dirLockPathFor(cwd)
    check readFile(lp).strip.splitLines == @[$getCurrentProcessId(), "20260202T000000"]

  test "pid-only dir lock (no session line) still reports the pid":
    let cwd = "/home/carlo/p/test-dir-lock-bare"
    acquireDirLock(cwd)
    let lp = dirLockPathFor(cwd)
    check readFile(lp).strip == $getCurrentProcessId()
    var msg = ""
    try:
      acquireDirLock(cwd)
      fail()
    except DirLocked as e:
      msg = e.msg
    check "pid " & $getCurrentProcessId() in msg
    check "session" notin msg

  test "releaseDirLock keeps the persistent file, emptied of owner text":
    let cwd = "/home/carlo/p/test-dir-lock-rel"
    acquireDirLock(cwd)
    let lp = dirLockPathFor(cwd)
    check fileExists(lp)
    releaseDirLock(cwd)
    check fileExists(lp)
    check readFile(lp) == ""
    check activeDirLockPath() == ""

  test "releaseActiveDirLock clears ownership, keeps the file":
    let cwd = "/home/carlo/p/test-dir-lock-active"
    acquireDirLock(cwd)
    let lp = dirLockPathFor(cwd)
    check activeDirLockPath() == lp
    releaseActiveDirLock()
    check fileExists(lp)
    check readFile(lp) == ""
    check activeDirLockPath() == ""

  test "release of a never-held lock is a no-op":
    releaseDirLock("/home/carlo/p/test-dir-lock-never")
    check activeDirLockPath() == ""

  test "acquire on empty path is a no-op":
    acquireDirLock("")
    check activeDirLockPath() == ""

  test "distinct cwds get distinct locks":
    let cwdA = "/home/carlo/p/test-dir-lock-a"
    let cwdB = "/home/carlo/p/test-dir-lock-b"
    acquireDirLock(cwdA)
    acquireDirLock(cwdB)
    check dirLockPathFor(cwdA) != dirLockPathFor(cwdB)
    check fileExists(dirLockPathFor(cwdA))
    check fileExists(dirLockPathFor(cwdB))
    releaseDirLock(cwdB)
    releaseDirLock(cwdA)

  test "stale lock whose owner pid is dead is reclaimed in place and acquired":
    let cwd = "/home/carlo/p/test-dir-lock-stale"
    let deadPid = spawnDeadPid()
    check deadPid != getCurrentProcessId()

    let lp = dirLockPathFor(cwd)
    createDir(parentDir(lp))
    writeFile(lp, $deadPid)
    check fileExists(lp)
    when defined(posix):
      let inoBefore = inoOf(lp)

    acquireDirLock(cwd)
    check activeDirLockPath() == lp
    check readFile(lp).strip == $getCurrentProcessId()
    when defined(posix):
      check inoOf(lp) == inoBefore

  test "corrupt lock (non-numeric pid) is reclaimed and acquired":
    let cwd = "/home/carlo/p/test-dir-lock-corrupt"
    let lp = dirLockPathFor(cwd)
    createDir(parentDir(lp))
    writeFile(lp, "not-a-pid")
    check fileExists(lp)
    acquireDirLock(cwd)
    check activeDirLockPath() == lp
    check readFile(lp).strip == $getCurrentProcessId()

  test "empty lock file is reclaimed and acquired":
    let cwd = "/home/carlo/p/test-dir-lock-empty"
    let lp = dirLockPathFor(cwd)
    createDir(parentDir(lp))
    writeFile(lp, "")
    check fileExists(lp)
    acquireDirLock(cwd)
    check activeDirLockPath() == lp
    check readFile(lp).strip == $getCurrentProcessId()

suite "session: prompt draft sidecar":
  var tmpDir: string
  var savedXdg: string

  setup:
    # Redirect userDataRoot() into a temp dir so the test never touches the
    # real ~/.local/share/3code draft store.
    tmpDir = getTempDir() / "3code-test-draft-" & $getTime().toUnix()
    savedXdg = getEnv("XDG_DATA_HOME")
    putEnv("XDG_DATA_HOME", tmpDir)

  teardown:
    if savedXdg.len > 0: putEnv("XDG_DATA_HOME", savedXdg)
    else: delEnv("XDG_DATA_HOME")
    if dirExists(tmpDir):
      try: removeDir(tmpDir) except OSError: discard

  test "draftPathFor derives <id>.prompt from a session path":
    let p = tmpDir / "3code" / "sessions" / "20250101T120000.3log"
    check draftPathFor(p) == tmpDir / "3code" / "drafts" / "20250101T120000.prompt"

  test "pendingDraftPathFor derives <mangled-cwd>.prompt":
    let cwd = "/home/user/project"
    check pendingDraftPathFor(cwd) ==
      tmpDir / "3code" / "drafts" / "pending" / (mangleCwd(cwd) & ".prompt")

  test "currentDraftPath is pending when no .3log exists yet":
    # Pre-first-turn: savePath is set but the .3log is not on disk, so the
    # draft lives under the cwd-keyed pending path.
    let sess = Session(savePath: tmpDir / "3code" / "sessions" / "20250101T120000.3log",
                       cwd: "/home/user/project")
    check currentDraftPath(sess) == pendingDraftPathFor(sess.cwd)

  test "currentDraftPath switches to session-id key once .3log exists":
    # Post-first-turn: the .3log exists on disk, so the draft becomes
    # session-id-keyed (restored on resume).
    let savePath = tmpDir / "3code" / "sessions" / "20250101T120000.3log"
    createDir(savePath.parentDir)
    writeFile(savePath, "session exists")
    let sess = Session(savePath: savePath, cwd: "/home/user/project")
    check currentDraftPath(sess) == draftPathFor(savePath)

  test "draftAtSentenceEnd accepts completed sentences only":
    # The debounced save fires only when the buffer ends at a sentence
    # boundary, so mid-sentence text never hits the disk.
    check draftAtSentenceEnd("half-typed prompt about to be lost.")
    check draftAtSentenceEnd("really?!")
    check draftAtSentenceEnd("done. ")              # trailing space is fine
    check draftAtSentenceEnd("first line.\n")       # completed line
    check not draftAtSentenceEnd("half-typed prompt")
    check not draftAtSentenceEnd("half-typed prompt about to be")
    check not draftAtSentenceEnd("")
    check not draftAtSentenceEnd("   ")
    check not draftAtSentenceEnd("wait, not yet,")

  test "saveDraft writes the pending path before the .3log exists":
    let sess = Session(savePath: tmpDir / "3code" / "sessions" / "20250101T120000.3log",
                       cwd: "/home/user/project")
    saveDraft(sess, "half-typed prompt about to be lost")
    check fileExists(pendingDraftPathFor(sess.cwd))
    check loadPendingDraft(sess.cwd) == "half-typed prompt about to be lost"
    # No session-id draft exists yet.
    check not fileExists(draftPathFor(sess.savePath))

  test "saveDraft switches to session-id key after the .3log exists":
    let savePath = tmpDir / "3code" / "sessions" / "20250101T120000.3log"
    createDir(savePath.parentDir)
    writeFile(savePath, "session exists")
    let sess = Session(savePath: savePath, cwd: "/home/user/project")
    saveDraft(sess, "in-flight during a turn")
    check fileExists(draftPathFor(sess.savePath))
    check loadDraft(sess.savePath) == "in-flight during a turn"
    # Pending path was not (re)written by this save.
    check not fileExists(pendingDraftPathFor(sess.cwd))

  test "saveDraft with empty text removes the sidecar":
    let sess = Session(savePath: tmpDir / "3code" / "sessions" / "20250101T120000.3log",
                       cwd: "/home/user/project")
    saveDraft(sess, "something")
    check fileExists(pendingDraftPathFor(sess.cwd))
    saveDraft(sess, "")
    check not fileExists(pendingDraftPathFor(sess.cwd))

  test "clearDraft removes both scopes":
    # A pending draft plus a session draft both exist; clearDraft removes both
    # so a committed prompt leaves neither behind regardless of which was live.
    let cwd = "/home/user/project"
    let savePath = tmpDir / "3code" / "sessions" / "20250101T120000.3log"
    let sess = Session(savePath: savePath, cwd: cwd)
    createDir(pendingDraftPathFor(cwd).parentDir)
    writeFile(pendingDraftPathFor(cwd), "pending")
    createDir(draftPathFor(savePath).parentDir)
    writeFile(draftPathFor(savePath), "session")
    clearDraft(sess)
    check not fileExists(pendingDraftPathFor(cwd))
    check not fileExists(draftPathFor(savePath))

  test "clearDraft / clearPendingDraft are no-ops when nothing exists":
    let sess = Session(savePath: tmpDir / "3code" / "sessions" / "x.3log",
                       cwd: "/home/user/empty")
    clearDraft(sess)
    clearPendingDraft(sess.cwd)
    check not fileExists(pendingDraftPathFor(sess.cwd))
    check not fileExists(draftPathFor(sess.savePath))

  test "saveDraft / loadDraft are no-ops on empty savePath and cwd":
    let sess = Session(savePath: "", cwd: "")
    saveDraft(sess, "ignored")
    clearDraft(sess)
    check loadDraft("") == ""
    check loadPendingDraft("") == ""

  test "loadPendingDraft returns empty string when no sidecar exists":
    check loadPendingDraft("/home/user/nothing-here") == ""

  test "saveDraft writes atomically (no stray staging file left behind)":
    let sess = Session(savePath: tmpDir / "3code" / "sessions" / "20250101T120000.3log",
                       cwd: "/home/user/project")
    saveDraft(sess, "atomic write")
    let path = pendingDraftPathFor(sess.cwd)
    check fileExists(path)
    var siblings: seq[string]
    for f in walkFiles(path.parentDir / "*"): siblings.add f
    check siblings == @[path]

suite "session: cross-process lock ownership":
  # Real subprocesses contend for the same persistent lock files. Barriers
  # are files the workers write once they hold the lock (or finished their
  # attempt), so no test depends on timing loops. TMPDIR is inherited, so
  # workers share this process's isolated lock directory.
  var root: string

  setup:
    root = getTempDir() / ("3code-lockrace-" & $getCurrentProcessId())
    createDir(root)

  teardown:
    releaseActiveSessionLock()
    releaseActiveDirLock()
    try: removeDir(root) except OSError: discard

  test "contender refuses while the holder has not published owner metadata":
    # The holder owns the OS lock but its owner record (pid line) is not
    # written yet: exactly the window where an empty or stale-text file
    # used to let a contender delete the live creator's lock.
    var n = 0
    for pretext in ["", "999999999"]:   # empty file, and a never-real pid
      inc n
      let target = root / "unpublished.3log"
      let lp = sessionLockPathFor(target)
      let ready = root / ("raw" & $n & ".ready")
      let stop = root / ("raw" & $n & ".stop")
      try: removeFile(lp) except OSError: discard
      try: removeFile(ready) except OSError: discard
      try: removeFile(stop) except OSError: discard
      createDir(parentDir(lp))
      writeFile(lp, pretext)
      when defined(posix):
        let inoBefore = inoOf(lp)
      let holder = spawnLockWorker("--lockrawhold", target, ready, stop)
      check waitForBarrier(ready, 10)
      var refused = false
      try:
        acquireSessionLock(target)
      except SessionLocked:
        refused = true
      check refused
      # The contender neither deleted nor rewrote the holder's file, and
      # the holder still owns the lock afterwards.
      check fileExists(lp)
      check readFile(lp) == pretext
      check activeSessionLockPath() == ""
      writeFile(stop, "1")
      check holder.waitForExit(25000) == 0
      holder.close()
      when defined(posix):
        check inoOf(lp) == inoBefore
      # Holder gone: the unlocked file acquires cleanly.
      acquireSessionLock(target)
      releaseSessionLock(target)

  test "two contenders reclaiming the same legacy-stale lock yield one owner":
    let target = root / "stale.3log"
    let lp = sessionLockPathFor(target)
    createDir(parentDir(lp))
    writeFile(lp, $spawnDeadPid())
    let resA = root / "tryA"
    let resB = root / "tryB"
    var workers = @[spawnLockWorker("--locktry", target, resA),
                    spawnLockWorker("--locktry", target, resB)]
    # Barrier: release both from the rendezvous only once each has
    # announced itself, so they contend for real.
    let goDeadline = epochTime() + 10
    while epochTime() < goDeadline and
        not (fileExists(resA & ".started") and fileExists(resB & ".started")):
      sleep(20)
    writeFile(resA & ".go", "1")
    writeFile(resB & ".go", "1")
    # Workers publish their verdict with a plain write; wait until each
    # file carries a complete verdict before reading it.
    proc verdictComplete(path: string): bool =
      if not fileExists(path): return false
      let c = readFile(path)
      c == "refused" or (c.startsWith("owned:") and c.len > "owned:".len)
    let outDeadline = epochTime() + 20
    while epochTime() < outDeadline and
        not (verdictComplete(resA) and verdictComplete(resB)):
      sleep(20)
    check verdictComplete(resA) and verdictComplete(resB)
    let outcomes = sorted(@[readFile(resA), readFile(resB)])
    check outcomes.len == 2
    check outcomes[0].startsWith("owned:")
    check outcomes[1] == "refused"
    # Exactly one owner published its pid; the loser did not delete the
    # winner's lock.
    check fileExists(lp)
    check readFile(lp).strip == outcomes[0]["owned:".len .. ^1]
    writeFile(resA & ".done", "1")
    writeFile(resB & ".done", "1")
    for w in workers:
      check w.waitForExit(25000) == 0
      w.close()

  test "a killed owner's lock releases; the next owner acquires in place":
    let target = root / "killed.3log"
    let lp = sessionLockPathFor(target)
    let ready = root / "kill.ready"
    let stop = root / "kill.stop"
    let holder = spawnLockWorker("--lockhold", target, ready, stop)
    check waitForBarrier(ready, 10)
    when defined(posix):
      let inoBefore = inoOf(lp)
    hardKill(holder)
    acquireSessionLock(target)
    check activeSessionLockPath() == lp
    check readFile(lp).strip == $getCurrentProcessId()
    when defined(posix):
      check inoOf(lp) == inoBefore   # acquired without deleting the file
    releaseSessionLock(target)

  test "a non-owner's release cannot disturb another owner's lock":
    let target = root / "foreign.3log"
    let ready = root / "foreign.ready"
    let stop = root / "foreign.stop"
    let holder = spawnLockWorker("--lockhold", target, ready, stop)
    check waitForBarrier(ready, 10)
    # We hold nothing for `target`; this release must be a no-op.
    releaseSessionLock(target)
    check fileExists(sessionLockPathFor(target))
    var refused = false
    try:
      acquireSessionLock(target)
    except SessionLocked:
      refused = true
    check refused
    check activeSessionLockPath() == ""
    writeFile(stop, "1")
    check holder.waitForExit(25000) == 0
    holder.close()
    acquireSessionLock(target)
    releaseSessionLock(target)

  test "a spawned tool process does not retain the owner's lock":
    let target = root / "inherit.3log"
    let pidfile = root / "grand.pid"
    let execed = root / "grand.execed"
    let helper = spawnLockWorker("--lockspawnexit", target, pidfile, execed)
    check waitForBarrier(pidfile, 15)
    check helper.waitForExit(25000) != -1   # owner exited
    helper.close()
    let grandPid = parseInt(readFile(pidfile).strip)
    when defined(posix):
      # The grandchild is still running: any inherited lock fd would keep
      # the flock alive right now.
      check pidAlive(grandPid)
    acquireSessionLock(target)
    check activeSessionLockPath() == sessionLockPathFor(target)
    releaseSessionLock(target)
    when defined(posix):
      discard posix.kill(Pid(grandPid), SIGKILL)

  test "advisory probe reports the live owner and blocks nothing afterwards":
    let cwd = root / "probe-cwd"
    let sess = root / "20260101T000000.3log"
    let ready = root / "probe.ready"
    let stop = root / "probe.stop"
    let holder = spawnLockWorker("--dirlockhold", cwd, sess, ready, stop)
    check waitForBarrier(ready, 10)
    let msg = probeDirLockHeld(cwd)
    check "already open" in msg
    check $holder.processID() in msg
    check "session 20260101T000000" in msg
    check dirLockPathFor(cwd) in msg
    # The probe stole nothing: the holder still owns the directory.
    var refused = false
    try:
      acquireDirLock(cwd)
    except DirLocked:
      refused = true
    check refused
    # A separate process' probe agrees.
    let probeOut = root / "probe.out"
    let prober = spawnLockWorker("--dirprobe", cwd, probeOut)
    check prober.waitForExit(25000) == 0
    prober.close()
    check "already open" in readFile(probeOut)
    writeFile(stop, "1")
    check holder.waitForExit(25000) == 0
    holder.close()
    check probeDirLockHeld(cwd) == ""
    # Probing a free directory does not stand in the way of acquiring it.
    acquireDirLock(cwd, sess)
    releaseActiveDirLock()

  test "probe ignores stale text in an unlocked dir lock file":
    let cwd = root / "stale-probe-cwd"
    let lp = dirLockPathFor(cwd)
    createDir(parentDir(lp))
    writeFile(lp, $spawnDeadPid() & "\n20251231T235959")
    check probeDirLockHeld(cwd) == ""
    acquireDirLock(cwd)
    check activeDirLockPath() == lp
    releaseActiveDirLock()

  test "session and directory locks coexist; failed init releases only its own":
    let cwdA = root / "both-a"
    let s1 = root / "one.3log"
    acquireDirLock(cwdA, s1)
    acquireSessionLock(s1)
    check activeSessionLockPath() == sessionLockPathFor(s1)
    check activeDirLockPath() == dirLockPathFor(cwdA)
    # A second initialization attempt (library.init shape): dir lock ok,
    # session lock held by a live other process -> rollback releases the
    # dir lock of that attempt only.
    let cwdB = root / "both-b"
    let s2 = root / "two.3log"
    let ready = root / "both.ready"
    let stop = root / "both.stop"
    let holder = spawnLockWorker("--lockhold", s2, ready, stop)
    check waitForBarrier(ready, 10)
    acquireDirLock(cwdB)
    var refused = false
    try:
      acquireSessionLock(s2)
    except SessionLocked:
      refused = true
    check refused
    releaseDirLock(cwdB)
    check activeSessionLockPath() == sessionLockPathFor(s1)
    check activeDirLockPath() == dirLockPathFor(cwdA)
    writeFile(stop, "1")
    check holder.waitForExit(25000) == 0
    holder.close()
    releaseSessionLock(s1)
    releaseActiveDirLock()

# ---------------------------------------------------------------------------
# Atomic save with observable failure (finding 4).
#
# saveSession used to overwrite the live transcript in place and swallow
# errors into stderr: a truncated or half-written .3log silently replaced a
# valid one, and a failed first save still got indexed. Now every failure
# raises SessionSaveError with the previous transcript byte-for-byte intact.
# Ordinary fixtures cover what they can; the saveFaultHook injects the
# portable failure points ordinary OS fixtures cannot reach (short staging
# write, flush/close error, failed replacement).

suite "session: failed save preserves the previous transcript":
  var root: string
  var savedXdg: string
  var seed = 0

  setup:
    savedXdg = getEnv("XDG_DATA_HOME")
    inc seed
    root = getTempDir() / ("3code-savefail-" & $getCurrentProcessId() & "-" & $seed)
    createDir(root)
    putEnv("XDG_DATA_HOME", root)

  teardown:
    saveFaultHook = nil
    if savedXdg.len > 0: putEnv("XDG_DATA_HOME", savedXdg)
    else: putEnv("XDG_DATA_HOME", "")
    removeDir(root)

  proc savedTranscript(content: string): string =
    ## A real first save through production code, so every later assertion
    ## starts from a valid, reloadable transcript.
    let s = Session(savePath: sessionDir() / ("20250101T100000" & SessionExt),
                    cwd: root / "proj")
    saveSession(s, %*[{"role": "user", "content": content}])
    doAssert fileExists(s.savePath)
    s.savePath

  proc sessionDirFiles(): seq[string] =
    for f in walkFiles(sessionDir() / "*"): result.add f

  proc faultAt(phase: SaveFaultPhase) {.gcsafe, raises: [CatchableError].} =
    raise newException(IOError, "injected fault at " & $phase)

  for phase in [sfpStageWrite, sfpFlushClose, sfpBeforeReplace]:
    test "fault in " & $phase & " preserves the old transcript byte-for-byte":
      let path = savedTranscript("first turn")
      let before = readFile(path)
      let s = Session(savePath: path, cwd: root / "proj")
      saveFaultHook = proc (p: SaveFaultPhase) {.gcsafe, raises: [CatchableError].} =
        if p == phase: faultAt(p)
      expect SessionSaveError:
        saveSession(s, %*[{"role": "user", "content": "second turn"}])
      saveFaultHook = nil
      check readFile(path) == before
      # The preserved file is still a loadable transcript of the old turn.
      let (_, msgs) = loadSessionFile(path)
      check msgs.len == 2
      check userTextContent(msgs[1]) == "first turn"
      # No staging file is left behind, and the failed turn added no index
      # entry: discovery still names exactly the first-save session.
      check sessionDirFiles() == @[path]
      check indexIdsAt(sessionPathIndexDir(), s.cwd) ==
        @[sessionIdFromPath(path)]

  test "fault after replacement does not unwind as a failed save":
    # The rename is the commit point: everything before it preserves the
    # old file, everything after it must not claim the save failed.
    let path = savedTranscript("first turn")
    let s = Session(savePath: path, cwd: root / "proj")
    saveSession(s, %*[{"role": "user", "content": "second turn"}])
    check "second turn" in readFile(path)

  test "failed first save writes no content and no index entry":
    # Startup reserves an empty .3log; the first save failing must leave
    # exactly that reservation behind.
    createDir(sessionDir())
    let path = sessionDir() / ("20250102T100000" & SessionExt)
    writeFile(path, "")
    let s = Session(savePath: path, cwd: root / "proj")
    saveFaultHook = faultAt
    expect SessionSaveError:
      saveSession(s, %*[{"role": "user", "content": "lost turn"}])
    saveFaultHook = nil
    check getFileSize(path) == 0
    check sessionDirFiles() == @[path]
    check indexIdsAt(sessionPathIndexDir(), s.cwd).len == 0

  test "unresolvable target fails loudly without any hook":
    # Ordinary fixture: the parent of the save path is a regular file, so
    # directory creation itself fails before anything is written.
    writeFile(root / "blocker", "x")
    let s = Session(savePath: root / "blocker" / "x.3log", cwd: "")
    expect SessionSaveError:
      saveSession(s, %*[{"role": "user", "content": "x"}])
    check not fileExists(root / "blocker" / "x.3log")

  when defined(posix):
    test "read-only sessions directory preserves the old transcript":
      if geteuid() == 0: skip()
      else:
        let path = savedTranscript("first turn")
        let before = readFile(path)
        let dir = sessionDir()
        setFilePermissions(dir, {fpUserRead, fpUserExec})
        let s = Session(savePath: path, cwd: root / "proj")
        expect SessionSaveError:
          saveSession(s, %*[{"role": "user", "content": "second turn"}])
        setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec})
        check readFile(path) == before
        check sessionDirFiles() == @[path]

  # Windows CI runners cannot create symlinks without privileges; the
  # replacement-over-existing-file cases above run there unguarded.
  when defined(posix):
    test "a symlinked -s target saves through the link":
      # Documented contract for custom `-s` paths: an existing symlink is
      # followed (writeFile-era behavior), the atomic rename replaces the
      # link's target and never the link itself, so the user's link keeps
      # working across saves.
      let target = root / "real" / "target.3log"
      let link = root / "custom.3log"
      createSymlink(target, link)
      var s = Session(savePath: link, cwd: "")
      var msgs = %*[{"role": "user", "content": "old bytes"}]
      saveSession(s, msgs)
      check symlinkExists(link)
      check "old bytes" in readFile(target)
      msgs.add %*{"role": "user", "content": "new bytes"}
      saveSession(s, msgs)
      check symlinkExists(link)
      let text = readFile(link)
      check "old bytes" in text
      check "new bytes" in text

  test "a failed index append repairs on the next save":
    # Block discovery by making the index directory path a regular file;
    # the transcript still commits and the failure is retryable.
    createDir(sessionPathIndexDir().parentDir)
    writeFile(sessionPathIndexDir(), "blocker")
    let path = savedTranscript("first turn")
    let s = Session(savePath: path, cwd: root / "proj")
    check fileExists(path)
    check indexIdsAt(sessionPathIndexDir(), s.cwd).len == 0
    removeFile(sessionPathIndexDir())
    saveSession(s, %*[{"role": "user", "content": "second turn"}])
    check indexIdsAt(sessionPathIndexDir(), s.cwd) ==
      @[sessionIdFromPath(path)]

  proc imageMessage(body: string): JsonNode =
    ## One user turn carrying one image content block, shaped exactly like
    ## the wire message renderSession persists — the delivered bytes ride
    ## the data URI, never a file.
    %*{"role": "user", "content": [
      %*{"type": "text", "text": body},
      %*{"type": "image_url",
         "image_url": {"url": "data:image/png;base64," &
                               base64.encode("fake png bytes")}}]}

  test "a failed image write fails the save, old transcript intact":
    let path = savedTranscript("first turn")
    let before = readFile(path)
    let s = Session(savePath: path, cwd: root / "proj")
    # The per-session image store cannot be created: its path is occupied
    # by a regular file, so renderSession cannot deliver the image bytes.
    writeFile(sessionImageDir(path), "blocker")
    expect SessionSaveError:
      saveSession(s, %*[imageMessage("attached")])
    check readFile(path) == before
    # The committed transcript never references the missing image data:
    # preservation means the old records only.
    check "image path=" notin readFile(path)

  test "saved image records reference delivered bytes":
    let path = savedTranscript("first turn")
    let s = Session(savePath: path, cwd: root / "proj")
    saveSession(s, %*[imageMessage("attached")])
    let text = readFile(path)
    let line = block:
      var found = ""
      for l in text.splitLines():
        if l.startsWith("image path="): found = l
      found
    check line.len > 0
    let imgPath = line.split(" path=")[1].split(' ')[0]
    check fileExists(imgPath)
    check "fake png bytes" == readFile(imgPath)

  test "successful replacement keeps the transcript owner-only":
    let path = savedTranscript("first turn")
    let s = Session(savePath: path, cwd: root / "proj")
    saveSession(s, %*[{"role": "user", "content": "second turn"}])
    when defined(posix):
      check getFilePermissions(path) == {fpUserRead, fpUserWrite}
    check sessionDirFiles() == @[path]

  when defined(posix):
    test "the staging file is owner-only while it exists":
      # Inspected from inside the save, at the last point before the
      # replacement: a transcript (or draft) staging file must never be
      # world-readable, not even for the instant it exists.
      let path = savedTranscript("first turn")
      var stagedPerms: set[FilePermission] = {}
      var sawStaging = false
      saveFaultHook = proc (p: SaveFaultPhase) {.gcsafe, raises: [CatchableError].} =
        if p == sfpBeforeReplace:
          for f in walkFiles(sessionDir() / "3code-*.stage"):
            sawStaging = true
            stagedPerms = getFilePermissions(f)
      let s = Session(savePath: path, cwd: root / "proj")
      try:
        saveSession(s, %*[{"role": "user", "content": "second turn"}])
      finally:
        saveFaultHook = nil
      check sawStaging
      check stagedPerms == {fpUserRead, fpUserWrite}
      check sessionDirFiles() == @[path]
