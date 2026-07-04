import std/[os, unittest, tables]
import threecode/[util, types]

suite "color mode detection":
  setup:
    putEnv("COLORFGBG", "0;0")

  test "COLORFGBG dark background stays dark":
    putEnv("COLORFGBG", "0;0")
    check detectColorMode(cmDark) == cmDark
    putEnv("COLORFGBG", "7;0")
    check detectColorMode(cmDark) == cmDark

  test "COLORFGBG light background selects light":
    putEnv("COLORFGBG", "0;15")
    check detectColorMode(cmDark) == cmLight
    putEnv("COLORFGBG", "default;15")
    check detectColorMode(cmDark) == cmLight

  test "--light force wins over a dark background":
    putEnv("COLORFGBG", "0;0")
    check detectColorMode(cmLight) == cmLight

  test "missing/unknown COLORFGBG defaults to dark":
    putEnv("COLORFGBG", "garbage")
    check detectColorMode(cmDark) == cmDark

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
    check CyanFg == "\x1b[36m"                 # brand tone, mode-independent
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
