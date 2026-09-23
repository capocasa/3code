## Reproduction probe: "sometimes, sending a prompt removes the line above
## the prompt; never on the first prompt."
##
## Drives the stub binary through several submits with the LIVE gui thread
## (THREECODE_TEST_GUI_LIVE=1) and tracks, for every committed marker line
## (echoes, answers, receipts), whether it survives on screen from the
## moment it appeared until session end. A marker that disappears while the
## screen never scrolled (banner still on row 1) was erased in place: the
## reported bug.
##
## Modes (env):
##   PROBE_QUEUED=1    type the next prompt while the previous turn streams
##                     (deferred submit + auto-send at turn end)
##   PROBE_FUSED=1     last char + Enter in one write
##   PROBE_REASONING=1 reasoning = on in config
##   PROBE_COLS=N      terminal width
##
## Usage: probe_submit_eat [iterations] [turnsPerSession]

import std/[json, os, strutils]
import tty_expect, stub_helpers
when true:
  import mock_server
from std/times import epochTime

proc newFixture(name: string): string =
  result = getCurrentDir() / "tests/testdata" / "output" / "tty" /
    (name & "_" & $getCurrentProcessId())
  if dirExists(result): removeDir(result)
  createDir(result)
  createDir(result / "data")
  createDir(result / "run")

proc writeConfiguredProvider(root: string; reasoning = false) =
  createDir(root / "xdg" / "3code")
  let reasoningLine = if reasoning: "reasoning = on\n" else: ""
  writeFile(root / "xdg" / "3code" / "config", """
[settings]
current = "stub.stub-model"

[provider]
name = "stub"
url = "stub://provider"
key = "stub"
family = "glm"
models = "stub-model"
""" & reasoningLine)

proc writeStubResponses(root: string; responses: JsonNode) =
  writeFile(root / "run" / "stub_responses.json", $responses)

proc stubEnv(root, responsesPath: string; guiLive: bool): seq[EnvVar] =
  createDir(root / "tmp")
  result = @[
    (key: "TERM", val: "xterm-256color"),
    (key: "PATH", val: getEnv("PATH")),
    (key: "HOME", val: root),
    (key: "TMPDIR", val: root / "tmp"),
    (key: "XDG_CONFIG_HOME", val: root / "xdg"),
    (key: "XDG_DATA_HOME", val: root / "data"),
    (key: "THREECODE_STUB_RESPONSES", val: responsesPath),
  ]
  if guiLive:
    result.add (key: "THREECODE_TEST_GUI_LIVE", val: "1")

proc rawSend(s: TtySession; text: string) =
  for ch in text:
    s.send $ch
    s.drain(2)

proc bannerAnchor(rows: seq[string]): string =
  ## A stable top-of-screen signature: when this changes, the screen
  ## scrolled and missing rows above are legitimate.
  rows[min(2, rows.len - 1)]

type SessionState = object
  markers: seq[string]        # committed texts to track
  banner: string              # screen-top anchor at marker birth
  failures: seq[string]

proc checkSurvivors(s: TtySession; st: var SessionState) =
  if s.frames.len == 0: return
  let f = s.frames[^1]
  let scrolled = bannerAnchor(f.rows) != st.banner
  if scrolled: return
  for m in st.markers:
    var found = false
    for row in f.rows:
      if m in row:
        found = true
        break
    if not found:
      st.failures.add "marker \"" & m & "\" erased in place (banner stable)"
      var dump = ""
      for i, row in f.rows:
        dump.add align($i, 2) & " |" & row & "|\n"
      st.failures.add dump & s.dumpFramesAround(m)

proc addMarker(s: TtySession; st: var SessionState; m: string) =
  if s.frames.len == 0: return
  st.markers.add m
  st.banner = bannerAnchor(s.frames[^1].rows)

proc writeRealProviderConfig(root, url: string; reasoning: bool) =
  createDir(root / "xdg" / "3code")
  let reasoningLine = if reasoning: "reasoning = on\n" else: ""
  writeFile(root / "xdg" / "3code" / "config", """
[settings]
current = "mock.glm"

[provider]
name = "mock"
url = "$#"
key = "mock"
family = "glm"
models = "glm"
""" % url & reasoningLine)

proc realEnv(root: string; guiLive: bool): seq[EnvVar] =
  createDir(root / "tmp")
  result = @[
    (key: "TERM", val: "xterm-256color"),
    (key: "PATH", val: getEnv("PATH")),
    (key: "HOME", val: root),
    (key: "TMPDIR", val: root / "tmp"),
    (key: "XDG_CONFIG_HOME", val: root / "xdg"),
    (key: "XDG_DATA_HOME", val: root / "data"),
    (key: "XDG_CACHE_HOME", val: root / "xdg" / "cache"),
  ]
  if guiLive:
    result.add (key: "THREECODE_TEST_GUI_LIVE", val: "1")

proc separatorCheck(tty: TtySession; turnsDone: int): string =
  ## On a settled screen, every committed echo row (a row starting with the
  ## prompt glyph) must have exactly one blank row above it: the separator
  ## the submit erase eats when it over-walks. The bottom-most ❯ row is the
  ## live prompt (the bar row above it is not blank by design), so it is
  ## exempt. Covers prompt echoes and colon-command echoes alike.
  let rows = tty.rows()
  var echoes: seq[int]
  for i, row in rows:
    if row.startsWith("❯"): echoes.add i
  if echoes.len > 1:
    for e2 in echoes[0 ..< ^1]:
      if e2 - 1 >= 0 and rows[e2 - 1].strip.len > 0:
        var dump = ""
        for i, row in rows:
          dump.add align($i, 2) & " |" & row & "|\n"
        return "echo row " & $e2 & " has no blank separator above it " &
          "(row " & $(e2 - 1) & " = '" & rows[e2 - 1] & "')\n" & dump

proc seedSession(root: string; bin: string; cols, rows: int;
                 guiLive: bool) =
  ## PROBE_RESUME phase 1: two stub turns, then a clean quit, so phase 2
  ## starts from --resume scrollback with a painted usage bar.
  createDir(root / "run")
  writeFile(root / "run" / "stub_p1.json", $ %*[
    {"role": "assistant", "content": "phase1 end 1",
      "contentChunks": ["phase1 end 1"], "usage": {"promptTokens": 30,
      "completionTokens": 5, "totalTokens": 35, "cachedTokens": 0}},
    {"role": "assistant", "content": "phase1 end 2",
      "contentChunks": ["phase1 end 2"], "usage": {"promptTokens": 60,
      "completionTokens": 6, "totalTokens": 66, "cachedTokens": 0}}])
  let tty = newTtySession(bin, args = ["-x", "-i"], cwd = root / "run",
      env = stubEnv(root, root / "run" / "stub_p1.json", guiLive),
      cols = cols, rows = rows)
  defer: tty.close()
  tty.expect "type a prompt"
  tty.expect "❯"
  for t in 1 .. 2:
    rawSend(tty, "seed turn " & $t)
    tty.send "\n"
    tty.expect "phase1 end " & $t
    tty.drain(400)
  tty.send ":q\n"
  tty.expectExit(0, timeoutMs = 5000)

proc oneSession(idx: int; turns: int; guiLive: bool): string =
  let real = getEnv("PROBE_REAL", "0") == "1"
  let root = newFixture("submit_eat_" & $idx)
  var srv: MockServer
  var bin: string
  if real:
    srv = startMockServer(
      if getEnv("PROBE_SCENARIO", "drip") == "dripNoUsage":
        msDripStreamNoUsage else: msDripStream,
      chunkDelayMs = 25)
    writeRealProviderConfig(root, srv.url,
                            getEnv("PROBE_REASONING", "1") == "1")
    bin = buildBinary("-d:ssl -d:testPlainHttp --threads:on", "3code_real")
  else:
    writeConfiguredProvider(root, getEnv("PROBE_REASONING", "0") == "1")
    bin = ensureStubBinary()
  var responses: seq[JsonNode] = @[]
  for t in 1 .. turns:
    responses.add %*{
      "role": "assistant",
      "content": "answer " & $t & " tail marker end" & $t,
      "contentChunks": ["answer ", $t & " ", "tail ", "marker ", "end" & $t],
      "contentChunkDelayMs": 60,
      "preStreamDelayMs": 400,
      "reasoning": "pondering turn " & $t,
      "reasoningChunks": ["pondering ", "turn " & $t],
      "usage": {"promptTokens": 40 * t, "completionTokens": 7,
                "totalTokens": 47, "cachedTokens": 0}
    }
  if not real:
    writeStubResponses(root, %responses)
  let cols = parseInt(getEnv("PROBE_COLS", "100"))
  let resume = not real and getEnv("PROBE_RESUME", "0") == "1"
  if resume:
    seedSession(root, bin, cols, 45, guiLive)
  let tty = newTtySession(bin,
                          args = (if resume: @["-x", "-i", "-r"]
                                  else: @["-x", "-i"]),
                          cwd = root / "run",
                          env = (if real: realEnv(root, guiLive)
                                 else: stubEnv(root, root / "run" / "stub_responses.json", guiLive)),
                          cols = cols, rows = 45)
  defer:
    if real: stopMockServer(srv)
    tty.writeFrameArtifact(root / "frames.txt")
    tty.close()

  if resume:
    tty.expect "● resumed"
  else:
    tty.expect "type a prompt"
  tty.expect "❯"
  if resume:
    # Phase 1's exit leaves its submitted text restored as a draft; clear
    # it so phase-2 prompts are not appended to it.
    tty.send "\x15"
    tty.drain(150)
  let queued = getEnv("PROBE_QUEUED", "0") == "1"
  let fused = getEnv("PROBE_FUSED", "0") == "1"
  let wrapped = getEnv("PROBE_WRAPPED", "0") == "1"
  let colon = getEnv("PROBE_COLON", "0") == "1"
  var st: SessionState
  var typedNext = false   # queued mode: prompt t+1 already typed mid-turn
  var apiTurn = 0         # colon commands consume no stub response
  for t in 1 .. turns:
    var prompt = "go number " & $t
    var marker = prompt[0 ..< min(10, prompt.len)]
    var isCmd = false
    if colon and t > 1 and t mod 2 == 0:
      # Colon commands commit echo+output as one bundle through the
      # restoreEditor=true path, a different commit geometry than a plain
      # prompt submit.
      isCmd = true
      # :session prints one row; :help's ~40-row output scrolls the whole
      # screen and defeats the banner-stability scroll detector.
      prompt = if t mod 4 == 2: ":model stub-model" else: ":session"
      marker = "❯ " & (if t mod 4 == 2: ":model stub" else: ":session")
    if wrapped and not isCmd:
      # Lengths straddling the wrap boundary: one short of the row, exactly
      # full, one past, and a clear two-row wrap.
      let target = [cols - 3, cols - 2, cols - 1, cols + 4][(t - 1) mod 4]
      while prompt.len < target - 3:
        prompt.add "ab "
      prompt.add " xy"
    if not isCmd: inc apiTurn
    let frag = prompt[0 ..< min(20, prompt.len)]
    if not typedNext:
      if fused:
        rawSend(tty, prompt[0 ..< ^1])
        tty.send $prompt[^1] & "\n"
      else:
        rawSend(tty, prompt)
        tty.expect frag
        tty.send "\n"
    typedNext = false
    addMarker(tty, st, marker)
    # Watch frames until this turn's answer settled and the app went idle.
    var deadline = epochTime() + 10.0
    var sawAnswer = false
    var typedMidTurn = false
    block watch:
      while epochTime() < deadline:
        discard tty.pollOnce(25, recordIdleFrame = true)
        checkSurvivors(tty, st)
        if st.failures.len > 0:
          return "iter " & $idx & " turn " & $t & ": " & st.failures.join("\n")
        if isCmd and tty.turnIdle:
          # Colon commands have no streamed answer; the settled state is
          # the committed echo (a ❯ row with the live prompt below it).
          let r = tty.rowContaining(marker)
          var bottom = -1
          for i, row in tty.rows():
            if row.startsWith("❯"): bottom = i
          if r >= 0 and bottom > r:
            sawAnswer = true
        if not real and tty.rowContaining("marker end" & $apiTurn) >= 0:
          sawAnswer = true
          addMarker(tty, st, "marker end" & $apiTurn)
        if real and tty.rowContaining("word24") >= 0:
          sawAnswer = true
        # Queued mode: type the NEXT prompt while this turn still streams.
        # Enter mid-turn defers (⧖ marker) and auto-sends at turn end.
        if queued and not typedMidTurn and t < turns and
            (sawAnswer or tty.rowContaining("pondering") >= 0):
          rawSend(tty, "go number " & $(t + 1))
          tty.send "\n"
          typedMidTurn = true
        if sawAnswer and tty.turnIdle:
          break watch
    if not sawAnswer:
      return "iter " & $idx & " turn " & $t & " answer never appeared\n" &
        tty.dumpFramesAround(frag)
    # Post-settle window: the queued auto-send (if any) commits right after
    # idle. Keep checking survivors while frames keep arriving.
    var settleUntil = epochTime() + 1.0
    while epochTime() < settleUntil:
      discard tty.pollOnce(40, recordIdleFrame = true)
      checkSurvivors(tty, st)
      if st.failures.len > 0:
        return "iter " & $idx & " turn " & $t & " post-settle: " &
          st.failures.join("\n")
    typedNext = typedMidTurn
  # Structural check on the settled screen: the blank separator above each
  # committed echo must exist (the submit erase must not eat it).
  tty.drain(400)
  let sep = separatorCheck(tty, turns)
  if sep.len > 0:
    return "iter " & $idx & ": " & sep & tty.dumpFramesAround("❯ go number 2")
  result = ""

when isMainModule:
  let iters = if paramCount() >= 1: parseInt(paramStr(1)) else: 10
  let turns = if paramCount() >= 2: parseInt(paramStr(2)) else: 5
  let guiLive = getEnv("PROBE_GUI_LIVE", "1") == "1"
  var failures = 0
  for i in 1 .. iters:
    let f =
      try:
        oneSession(i, turns, guiLive)
      except CatchableError as e:
        "iter " & $i & " EX " & $e.name & ": " & e.msg & "\n" &
          e.getStackTrace()
    if f.len > 0:
      inc failures
      echo "FAIL: ", f
    else:
      echo "iter ", i, " ok"
  echo "ran ", iters, " sessions x ", turns, " turns, ",
       failures, " failures"
  if failures > 0: quit(1)
