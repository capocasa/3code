import std/[os, posix, strformat, strutils, terminal, times]
import posix/termios

type
  Frame = object
    title: string
    rows: seq[string]

  TermMode = object
    saved: Termios
    flags: cint
    active: bool

const
  MinSpeed = -8
  MaxSpeed = 8
  InitialSpeed = 4

proc isHeader(line: string): bool =
  line.startsWith("===== frame ") and line.endsWith(" =====")

proc parseFrames(path: string): seq[Frame] =
  var current = Frame()
  var haveFrame = false

  for line in lines(path):
    if line.isHeader:
      if haveFrame:
        result.add current
      current = Frame(title: line)
      haveFrame = true
    elif haveFrame:
      current.rows.add line

  if haveFrame:
    result.add current

proc latestFramesPath(): string =
  let root = "tests" / "output" / "tty"
  if not dirExists(root):
    return ""

  var newestTime: times.Time
  var haveNewest = false
  for path in walkDirRec(root):
    if path.extractFilename == "frames.txt":
      let t = getLastModificationTime(path)
      if not haveNewest or t > newestTime:
        result = path
        newestTime = t
        haveNewest = true

proc enterRawMode(): TermMode =
  var mode: TermMode
  if tcGetAttr(STDIN_FILENO, addr mode.saved) != 0:
    return mode

  var raw = mode.saved
  raw.c_lflag = raw.c_lflag and not (ECHO or ICANON)
  raw.c_cc[VMIN] = 0.char
  raw.c_cc[VTIME] = 0.char
  if tcSetAttr(STDIN_FILENO, TCSANOW, addr raw) == 0:
    mode.flags = fcntl(STDIN_FILENO, F_GETFL, 0)
    discard fcntl(STDIN_FILENO, F_SETFL, mode.flags or O_NONBLOCK)
    mode.active = true
  mode

proc leaveRawMode(mode: TermMode) =
  if mode.active:
    discard tcSetAttr(STDIN_FILENO, TCSANOW, addr mode.saved)
    discard fcntl(STDIN_FILENO, F_SETFL, mode.flags)

proc pollKey(): string =
  var buf: array[16, char]
  let n = read(STDIN_FILENO, addr buf[0], buf.len)
  if n > 0:
    result = newString(n)
    copyMem(addr result[0], addr buf[0], n)

proc speedDelayMs(speed: int): int =
  240 - abs(speed) * 20

proc fitStatus(text: string; width: int): string =
  if width <= 0:
    return ""
  if text.len <= width:
    text & repeat(" ", width - text.len)
  elif width > 1:
    text[0 ..< width - 1] & ">"
  else:
    ">"

proc render(frames: openArray[Frame]; frameNo, speed: int; path: string) =
  let width = max(1, terminalWidth())
  let height = max(1, terminalHeight())
  stdout.write "\e[H\e[2J"

  let usableRows = max(0, height - 1)
  for i in 0 ..< min(usableRows, frames[frameNo].rows.len):
    stdout.write &"\e[{i + 1};1H"
    stdout.write frames[frameNo].rows[i]
    stdout.write "\e[K"

  if usableRows > frames[frameNo].rows.len:
    for i in frames[frameNo].rows.len ..< usableRows:
      stdout.write &"\e[{i + 1};1H\e[K"

  let state =
    if speed == 0: "paused"
    elif speed < 0: "back"
    else: "play"
  let status = &" {state} speed={speed:+d} frame={frameNo + 1}/{frames.len} path={path} "
  stdout.write &"\e[{height};1H"
  stdout.write "\e[7m"
  stdout.write fitStatus(status, width)
  stdout.write "\e[0m"
  stdout.flushFile()

proc usage() =
  quit "usage: nim r tools/pty_frames.nim -- [tests/output/tty/.../frames.txt]", 2

proc main() =
  if paramCount() > 1:
    usage()

  let path =
    if paramCount() == 1: paramStr(1)
    else: latestFramesPath()
  if path.len == 0:
    quit "no frames.txt found under tests/output/tty", 1
  if not fileExists(path):
    quit "frames file not found: " & path, 1

  let frames = parseFrames(path)
  if frames.len == 0:
    quit "no frames parsed from: " & path, 1

  let mode = enterRawMode()
  var speed = InitialSpeed
  var lastSpeed = InitialSpeed
  var frameNo = 0
  var nextTick = epochTime()

  stdout.write "\e[?25l"
  try:
    while true:
      render(frames, frameNo, speed, path)

      let key = pollKey()
      if key == "q" or key == "\e":
        break
      elif key == " ":
        if speed == 0:
          speed = lastSpeed
        else:
          lastSpeed = speed
          speed = 0
      elif key == "\e[A":
        speed = min(MaxSpeed, speed + 1)
        if speed != 0:
          lastSpeed = speed
      elif key == "\e[B":
        speed = max(MinSpeed, speed - 1)
        if speed != 0:
          lastSpeed = speed

      let now = epochTime()
      if speed != 0 and now >= nextTick:
        frameNo = (frameNo + (if speed > 0: 1 else: -1) + frames.len) mod frames.len
        nextTick = now + speedDelayMs(speed).float / 1000.0

      sleep 20
  finally:
    stdout.write "\e[0m\e[?25h\e[H\e[2J"
    stdout.flushFile()
    leaveRawMode(mode)

when isMainModule:
  main()
