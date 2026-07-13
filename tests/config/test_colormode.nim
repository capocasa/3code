import std/[os, unittest, tables]
import threecode/[util, types]

suite "color mode resolution":
  test "forced dark stays dark":
    check detectColorMode(cmDark) == cmDark

  test "forced light stays light":
    check detectColorMode(cmLight) == cmLight

  test "auto in a non-tty defaults to dark":
    # Under the test runner stdin is not a tty, so OSC 11 is never sent
    # and detection falls back to dark rather than blocking.
    check detectColorMode(cmAuto) == cmDark

suite "OSC 11 background reply parsing":
  test "parseHex16 scales 1/2/4-digit channels to 0..255":
    check parseHex16("f") == 255
    check parseHex16("0") == 0
    check parseHex16("ff") == 255
    check parseHex16("00") == 0
    check parseHex16("7f") == 127
    check parseHex16("ffff") == 255
    check parseHex16("0000") == 0
    check parseHex16("") == 0

  test "parseOscBg reads rgb:RRRR/GGGG/BBBB form":
    let (r, g, b) = parseOscBg("\x1b]11;rgb:ffff/ffff/ffff\x07")
    check (r, g, b) == (255, 255, 255)

  test "parseOscBg reads 2-digit rgb form":
    let (r, g, b) = parseOscBg("\x1b]11;rgb:00/00/00\x07")
    check (r, g, b) == (0, 0, 0)

  test "parseOscBg reads bare #rrggbb form":
    let (r, g, b) = parseOscBg("\x1b]11;#1e1e1e\x07")
    check (r, g, b) == (0x1e, 0x1e, 0x1e)

  test "parseOscBg returns -1 on unparseable reply":
    check parseOscBg("") == (-1, -1, -1)
    check parseOscBg("garbage") == (-1, -1, -1)

  test "luminance is high for white, low for black":
    check luminance(255, 255, 255) > 0.9
    check luminance(0, 0, 0) < 0.1
  test "luminance threshold classifies light vs dark backgrounds":
    # Terminal.app "Basic" white profile is near-white; a typical dark
    # profile is near-black. The 0.5 cut must separate them.
    let (wr, wg, wb) = parseOscBg("\x1b]11;rgb:ffff/ffff/ffff\x07")
    check luminance(wr, wg, wb) > 0.5
    let (dr, dg, db) = parseOscBg("\x1b]11;rgb:0000/0000/0000\x07")
    check luminance(dr, dg, db) < 0.5

suite "palette application":
  teardown:
    resetPalettes()

  test "dark palette keeps bright-white as escape 97":
    applyPalette(cmDark)
    check BrightWhiteFg == "\x1b[97m"
    check OffWhiteFg == "\x1b[38;5;252m"
    check GreyFg == "\x1b[38;5;244m"

  test "light palette inverts the white family":
    applyPalette(cmLight)
    check BrightWhiteFg == "\x1b[30m"          # black
    check OffWhiteFg == "\x1b[38;5;238m"       # dark grey
    check GreyFg == "\x1b[38;5;250m"           # lighter dark grey

  test "colorful constants are unaffected by mode":
    applyPalette(cmLight)
    when defined(windows):
      check CyanFg == "\x1b[96m"               # bright cyan on Windows (true cyan there)
    else:
      check CyanFg == "\x1b[36m"               # brand tone, mode-independent
    check BoldOn == "\x1b[1m"
    check Reset == "\x1b[0m"

suite "color config cascade":
  teardown:
    resetPalettes()

  test "plain key overrides both modes":
    var both = initTable[string, string]()
    both["bright-white"] = "\x1b[37m"
    applyColorOverrides(both, initTable[string, string]())
    applyPalette(cmDark)
    check BrightWhiteFg == "\x1b[37m"
    applyPalette(cmLight)
    check BrightWhiteFg == "\x1b[37m"          # plain key hit light too

  test "light-suffixed key wins for light mode only":
    var both = initTable[string, string]()
    both["bright-white"] = "\x1b[37m"
    var light = initTable[string, string]()
    light["bright-white"] = "\x1b[90m"
    applyColorOverrides(both, light)
    applyPalette(cmDark)
    check BrightWhiteFg == "\x1b[37m"          # dark uses plain key
    applyPalette(cmLight)
    check BrightWhiteFg == "\x1b[90m"          # light uses -light key

suite "splitColorOverrides":
  test "plain key goes to both, -light key goes to light only":
    var flat = initTable[string, string]()
    flat["bright-white"] = "A"
    flat["bright-white-light"] = "B"
    flat["dim-white"] = "C"
    let (both, light) = splitColorOverrides(flat)
    check both.len == 2
    check both["bright-white"] == "A"
    check both["dim-white"] == "C"
    check light.len == 1
    check light["bright-white"] == "B"         # suffix stripped
