## RAM usage probe: spawn the real (stub-provider) 3code binary under a
## PTY and sample /proc/<pid> at each stage of a session's life - boot,
## idle, N stub turns, a large paste, exit, and a `-r` resume that
## re-renders the whole history. Prints one `RAM <stage> ...` line per
## sample for post-processing; the numbers, not pass/fail, are the point.
##
## Usage: probe_ram <stub-binary> [turns=40] [idle-secs=75]
##   (stub binary: build src/threecode.nim with -d:providerStub)
import std/[os, strutils, json, posix]
import ../tty_expect

proc dirSizeKb(path: string): int =
  var bytes = 0
  var stack = @[path]
  while stack.len > 0:
    let p = stack.pop()
    for k, f in walkDir(p):
      case k
      of pcFile:
        try: bytes += int(getFileSize(f))
        except CatchableError: discard
      of pcDir: stack.add f
      else: discard
  bytes div 1024
proc sample(tty: TtySession; stage: string; dataRoot: string) =
  if tty.exited or not fileExists("/proc/" & $tty.pid & "/status"):
    echo "RAM ", stage, " CHILD-EXITED code=", tty.exitCode
    echo "raw-tail: ", tty.raw[max(0, tty.raw.len - 500) ..< tty.raw.len]
    for row in tty.rows(): echo "| ", row
    quit 1
  var rssKb, vszKb: int
  var threads = -1
  if tty.pid > 0:
    for line in readFile("/proc/" & $tty.pid & "/status").splitLines:
      if line.startsWith("VmRSS:"): rssKb = line.splitWhitespace()[1].parseInt
      elif line.startsWith("VmSize:"): vszKb = line.splitWhitespace()[1].parseInt
      elif line.startsWith("Threads:"): threads = line.splitWhitespace()[1].parseInt
  echo "RAM ", stage, " rss=", rssKb, " vsz=", vszKb,
       " threads=", threads,
       " store=", dirSizeKb(dataRoot / "3code" / "sessions"), "kB"

proc newFixture(name: string): string =
  result = getTempDir() / ("3code_ramprobe_" & name & "_" & $getCurrentProcessId())
  if dirExists(result): removeDir(result)
  createDir(result)
  createDir(result / "xdg" / "3code")
  createDir(result / "data")
  createDir(result / "run")
  createDir(result / "tmp")
  writeFile(result / "xdg" / "3code" / "config",
    "[settings]\ncurrent = \"stub.stub-model\"\n\n[provider]\nname = \"stub\"\n" &
    "url = \"stub://provider\"\nkey = \"stub\"\nfamily = \"glm\"\n" &
    "models = \"stub-model\"\nreasoning = on\n\n" &
    "[params]\nmax-tokens = \"8192\"\n")

proc meatyChunks(prefix: string): JsonNode =
  result = newJArray()
  for i in 1 .. 60:
    result.add %(prefix & " segment " & $i &
      " with some ordinary sentence-length padding text")

proc writeResponses(root: string; n: int) =
  var arr = newJArray()
  for i in 1 .. n:
    # No reasoningChunks + small completionTokens + non-empty final
    # content: reasoningTokens > 0, completion >= max_tokens, or an empty
    # reply each trigger a turn-loop recovery (budget escalation or the
    # empty-steer resend), which burns an extra canned response per turn
    # and eventually exhausts the stub into an ApiError.
    arr.add %*{"content": "reply " & $i & " final text",
      "contentChunks": meatyChunks("reply" & $i),
      "usage": {"promptTokens": 2000 + i * 140, "completionTokens": 8,
                "totalTokens": 2300 + i * 140, "cachedTokens": 0}}
  # +1 for the paste turn
  arr.add %*{"content": "pasteback final text",
      "contentChunks": meatyChunks("pasteback"),
      "usage": {"promptTokens": 9000, "completionTokens": 8,
                "totalTokens": 9308, "cachedTokens": 0}}
  writeFile(root / "run" / "stub_responses.json", $arr)

proc startSession(bin, root: string; resume: bool): TtySession =
  let args = if resume: @["-x", "-r"] else: @["-x", "-i"]
  newTtySession(bin, args = args, cwd = root / "run",
    env = @[(key: "TERM", val: "xterm-256color"),
            (key: "PATH", val: getEnv("PATH")),
            (key: "HOME", val: root),
            (key: "TMPDIR", val: root / "tmp"),
            (key: "XDG_CONFIG_HOME", val: root / "xdg"),
            (key: "XDG_DATA_HOME", val: root / "data"),
            (key: "THREECODE_STUB_RESPONSES",
             val: root / "run" / "stub_responses.json")],
    cols = 119, rows = 40)

proc chunkedSend(tty: TtySession; text: string; piece = 1800) =
  ## send() writes once; a >64 kB pty paste would be truncated, so feed
  ## paste-sized input in pieces the editor can drain between.
  var i = 0
  while i < text.len:
    let n = min(piece, text.len - i)
    tty.send text[i ..< i + n]
    tty.drain(40)
    i += n

when isMainModule:
  let bin = paramStr(1)
  let turns = if paramCount() >= 2: parseInt(paramStr(2)) else: 40
  let idleSecs = if paramCount() >= 3: parseInt(paramStr(3)) else: 75
  let root = newFixture("main")
  writeResponses(root, turns)

  # --- boot + idle -------------------------------------------------------
  let tty = startSession(bin, root, resume = false)
  tty.expect "type a prompt"
  tty.drain(500)
  tty.sample("boot", root / "data")
  for i in 1 .. idleSecs div 15:
    tty.drain(15_000)
    tty.sample("idle" & $i, root / "data")

  # --- turns -------------------------------------------------------------
  for i in 1 .. turns:
    for ch in "turn " & $i & " plain user text":
      tty.send $ch
      tty.drain(2)
    tty.send "\n"
    tty.expect "reply" & $i & " segment 60"
    tty.drain(250)
    if i mod 5 == 0: tty.sample("turn" & $i, root / "data")
  tty.sample("turns_done", root / "data")

  # --- big paste ---------------------------------------------------------
  tty.sample("before_paste", root / "data")
  var big = ""
  for i in 1 .. 64: big.add "x".repeat(120) & " "  # ~8 kB, one line
  tty.chunkedSend big
  tty.drain(800)
  tty.sample("paste_buffered", root / "data")
  tty.send "\n"
  # A multi-thousand-column echo line commits row by row; give the child
  # real time instead of expect's 4 s quiet cap.
  tty.expect "pasteback segment 1"
  tty.drain(8000)
  tty.sample("paste_submitted", root / "data")

  tty.close()

  # --- resume: full history reload + render ------------------------------
  let tty2 = startSession(bin, root, resume = true)
  tty2.expect "type a prompt"
  tty2.drain(600)
  tty2.sample("resume", root / "data")
  tty2.close()
  echo "probe done; fixture at ", root
