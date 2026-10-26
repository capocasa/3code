discard """
  targets: "c"
"""
## Computer-use backend units: the generated `shot` script's coordinate
## mapping and staleness contract, executed against a fake xdotool (no X
## server needed); the capture seam; receipt/banner round-trip.

import std/[os, osproc, sequtils, strutils, unittest]
import threecode/[images, screen, types]

const FakeDisplay = "1920 1080"   # what the stubbed xdotool reports

proc fixture(name: string): string =
  result = getTempDir() / ("3code_screen_" & name & "_" & $getCurrentProcessId())
  if dirExists(result): removeDir(result)
  createDir(result / "bin")
  putEnv("TMPDIR", result)
  createDir(result / "tmp")

proc fakeXdotool(dir: string) =
  writeFile(dir / "bin" / "xdotool", """#!/bin/sh
echo "$@" >> "${XDOTOOL_LOG:-/dev/null}"
case "$*" in
  *getdisplaygeometry*) echo """ & quoteShell(FakeDisplay) & """ ;;
  *getactivewindow*) echo "fakewindow" ;;
esac
exit 0
""")
  let perm = {fpUserRead, fpUserWrite, fpUserExec,
              fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec}
  setFilePermissions(dir / "bin" / "xdotool", perm)

proc runShot(dir, args: string): tuple[output: string, exitCode: int] =
  let script = screen.shotScriptPath("sess")
  doAssert fileExists(script), script
  let log = dir / "xdotool.log"
  putEnv("XDOTOOL_LOG", log)
  let savedPath = getEnv("PATH")
  putEnv("PATH", dir / "bin:" & savedPath)
  defer: putEnv("PATH", savedPath)
  execCmdEx(script.quoteShell & " " & args)

proc shotLog(dir: string): string =
  try: readFile(dir / "xdotool.log") except CatchableError: ""

proc writeState(native, delivered: string) =
  let dir = screen.shotDir("sess")
  require screen.materializeShotScript(dir).len == 0
  writeFile(dir / "state",
    "native=" & native & "\ndelivered=" & delivered & "\n")

suite "shot script: coordinate mapping":
  let work = fixture("map")
  fakeXdotool(work)
  writeState("1920x1080", "1280x720")

  test "click maps delivered raster to native pixels":
    let (_, code) = runShot(work, "click 640 360")
    check code == 0
    check shotLog(work).contains("mousemove 960 540 click 1")

  test "rounding and edge clamping":
    discard runShot(work, "click 1279 719")
    check shotLog(work).contains("mousemove 1919 1079 click 1")
    discard runShot(work, "click 5000 360")
    check shotLog(work).contains("mousemove 1919 540 click 1")

  test "buttons pick the right button number":
    discard runShot(work, "rightclick 10 10")
    check shotLog(work).contains("click 3")
    discard runShot(work, "middleclick 10 10")
    check shotLog(work).contains("click 2")
    discard runShot(work, "doubleclick 10 10")
    check shotLog(work).contains("click --repeat 2 --delay 120 1")

  test "drag maps both endpoints":
    discard runShot(work, "drag 100 100 400 400")
    check shotLog(work).contains(
      "mousemove 150 150 mousedown 1 mousemove --sync 600 600 mouseup 1")

  test "type, key and scroll pass through":
    discard runShot(work, "type " & quoteShell("hello world"))
    check shotLog(work).contains("type -- hello world")
    discard runShot(work, "key ctrl+s")
    check shotLog(work).contains("key ctrl+s")
    discard runShot(work, "scroll down 5")
    check shotLog(work).contains("click --repeat 5 5")
    discard runShot(work, "scroll up 3")
    check shotLog(work).contains("click --repeat 3 4")

  test "title reports geometry and scale":
    let (outp, code) = runShot(work, "title")
    check code == 0
    check outp.contains("native: 1920x1080")
    check outp.contains("delivered: 1280x720")
    check outp.contains("scale: 1.500")

suite "shot script: stale frame contract":
  let work = fixture("stale")
  fakeXdotool(work)

  test "no state file is a loud error naming screenshot()":
    let dir = screen.shotDir("sess")
    require screen.materializeShotScript(dir).len == 0
    let script = screen.shotScriptPath("sess")
    let savedPath = getEnv("PATH")
    putEnv("PATH", work / "bin:" & savedPath)
    let (outp, code) = execCmdEx(script.quoteShell & " click 640 360")
    putEnv("PATH", savedPath)
    check code == 1
    check "screenshot()" in outp

  test "resolution change invalidates the frame":
    writeState("800x600", "800x600")
    let (outp, code) = runShot(work, "click 400 300")
    check code == 1
    check "stale frame" in outp
    check "screenshot()" in outp

  test "missing xdotool is named, not a shell traceback":
    writeState("1920x1080", "1920x1080")
    let script = screen.shotScriptPath("sess")
    let savedPath = getEnv("PATH")
    putEnv("PATH", work / "empty")
    createDir(work / "empty")
    let (outp, code) = execCmdEx(script.quoteShell & " click 640 360")
    putEnv("PATH", savedPath)
    check code == 1
    check outp.contains("xdotool not found")

  test "unknown subcommand lists the vocabulary":
    writeState("1920x1080", "1920x1080")
    let (outp, code) = runShot(work, "poke 1 2")
    check code == 1
    check "unknown subcommand" in outp

suite "screen capture (seam)":
  let work = fixture("cap")
  let x11Ready = getEnv("DISPLAY").len > 0 and
    findExe("xdotool").len > 0 and
    ["import", "maim", "scrot"].anyIt(findExe(it).len > 0)

  test "backend probe succeeds on X11":
    if not x11Ready: skip()
    let (ok, err) = screen.ensureComputerUse("cap1")
    check ok
    check err == ""
    check fileExists(screen.shotScriptPath("cap1"))

  test "capture via THREECODE_SCREENSHOT_SRC delivers and binds state":
    if not x11Ready: skip()
    require screen.ensureComputerUse("cap1").ok
    putEnv("THREECODE_SCREENSHOT_SRC", "testdata/images/tiny.png")
    defer: putEnv("THREECODE_SCREENSHOT_SRC", "")
    let dest = work / "img"
    let (info, err) = captureScreenshot(dest)
    check err == ""
    check info.screenshot
    check info.name == "shot 1"
    check info.width == 16 and info.height == 12
    check fileExists(dest / "001.jpeg")
    let st = readFile(screen.shotDir("cap1") / "state")
    check st.contains("native=16x12")
    check st.contains("delivered=16x12")
    # Second capture gets the next index, never overwriting delivered bytes.
    let (info2, _) = captureScreenshot(dest)
    check info2.name == "shot 2"
    check fileExists(dest / "002.jpeg")

  test "fidelity flag delivers PNG":
    if not x11Ready: skip()
    require screen.ensureComputerUse("cap1").ok
    putEnv("THREECODE_SCREENSHOT_SRC", "testdata/images/tiny.png")
    defer: putEnv("THREECODE_SCREENSHOT_SRC", "")
    let (info, err) = captureScreenshot(work / "img2", fidelity = true)
    check err == ""
    check info.format == "png"
    check fileExists(work / "img2" / "001.png")

suite "platform gate":
  test "X11/Linux probe is platform-clean; Wayland-only sessions refuse":
    # This dev platform is X11 Linux: no platform error before the
    # binary-level checks (DISPLAY etc. are exercised by the capture
    # suite). A Wayland session without Xwayland must get the named
    # not-here-yet error instead of a half-working backend.
    when defined(macosx) or defined(windows):
      skip()
    else:
      let savedWayland = getEnv("WAYLAND_DISPLAY")
      let savedDisplay = getEnv("DISPLAY")
      putEnv("WAYLAND_DISPLAY", "wayland-0")
      putEnv("DISPLAY", "")
      let (ok, err) = screen.ensureComputerUse("plat")
      check not ok
      check "Wayland" in err
      check "grim" in err
      putEnv("WAYLAND_DISPLAY", savedWayland)
      putEnv("DISPLAY", savedDisplay)

suite "screenshot receipt/banner":
  test "round trip":
    let info = ImageInfo(width: 1920, height: 1080,
      deliveredWidth: 1280, deliveredHeight: 720, format: "jpeg",
      name: "shot 3", screenshot: true)
    let r = screenshotReceipt(info)
    check isScreenshotReceipt(r)
    check not isImageReceipt(r)
    check screenshotBanner(r) == "· shot 1920x1080 -> 1280x720"
