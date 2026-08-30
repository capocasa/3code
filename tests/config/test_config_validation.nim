discard """
  # Spawns the 3code binary for the end-to-end exit-code checks; the
  # in-process validateConfig checks run everywhere.
  disabled: "win"
"""
import std/[os, osproc, strutils, unittest]
import threecode/config

const binName = when defined(windows): "3code.exe" else: "3code"

proc binPath(): string = getCurrentDir() / binName

suite "config validation: schema (in-process)":
  const P = "/tmp/cfg.ini"

  test "clean config returns empty string":
    let entries = @[
      ("settings", "current", "p.m", 2),
      ("provider", "name", "x", 5),
      ("provider", "url", "https://api.x.com", 6),
      ("provider", "key", "sk-x", 7),
      ("provider", "models", "m1 m2", 8),
      ("search", "engine", "brave", 11),
      ("search", "brave-key", "bk", 12),
      ("colors", "bright-white", "\\x1b[37m", 15),
      ("colors", "bright-white-light", "\\x1b[30m", 16),
    ]
    check validateConfig(P, entries) == ""

  test "unknown section is reported with path:line":
    let entries = @[("foo", "bar", "baz", 3)]
    let m = validateConfig(P, entries)
    check m == P & ":3: unknown section [foo]"

  test "unknown key in [settings] is reported":
    let entries = @[("settings", "foo", "bar", 4)]
    let m = validateConfig(P, entries)
    check m == P & ":4: unknown key 'foo' in [settings]"

  test "unknown key in [search] is reported":
    let entries = @[("search", "foo", "bar", 4)]
    let m = validateConfig(P, entries)
    check m == P & ":4: unknown key 'foo' in [search]"

  test "unknown key in [colors] is reported":
    let entries = @[("colors", "hot-pink", "\\x1b[31m", 3)]
    let m = validateConfig(P, entries)
    check m == P & ":3: unknown key 'hot-pink' in [colors]"

  test "unknown key in [provider] is reported":
    let entries = @[("provider", "foo", "bar", 4)]
    let m = validateConfig(P, entries)
    check m == P & ":4: unknown key 'foo' in [provider]"

  test "permitted [colors] -light suffix is accepted":
    let entries = @[("colors", "off-white-light", "\\x1b[38;5;238m", 3)]
    check validateConfig(P, entries) == ""

  test "unknown search engine value is reported":
    let entries = @[("search", "engine", "foo", 3)]
    let m = validateConfig(P, entries)
    check m == P & ":3: unknown search engine 'foo' (expected one of: exa, parallel, brave)"

  test "permitted search engines are accepted":
    for eng in ["exa", "parallel", "brave", "Brave", "EXA"]:
      let entries = @[("search", "engine", eng, 3)]
      check validateConfig(P, entries) == ""

  test "unknown tone value is reported":
    for key in ["tone", "mode"]:
      let entries = @[("settings", key, "purple", 3)]
      let m = validateConfig(P, entries)
      check m == P & ":3: unknown tone 'purple' (expected one of: auto, dark, light)"

  test "permitted tone values are accepted":
    for md in ["auto", "dark", "light", "bright", "Light"]:
      for key in ["tone", "mode"]:
        let entries = @[("settings", key, md, 3)]
        check validateConfig(P, entries) == ""

  test "bad boolean value for notify is reported":
    let entries = @[("settings", "notify", "maybe", 3)]
    let m = validateConfig(P, entries)
    check m == P & ":3: bad value 'maybe' for 'notify' (expected on/off/true/false/yes/no/1/0)"

  test "bad boolean value for streaming is reported":
    let entries = @[("settings", "streaming", "perhaps", 3)]
    let m = validateConfig(P, entries)
    check "bad value 'perhaps' for 'streaming'" in m

  test "bad boolean value for sandbox is reported":
    let entries = @[("settings", "sandbox", "sometimes", 3)]
    let m = validateConfig(P, entries)
    check "bad value 'sometimes' for 'sandbox'" in m

  test "bad boolean value for patient_retry is reported":
    let entries = @[("settings", "patient_retry", "maybe", 3)]
    let m = validateConfig(P, entries)
    check "bad value 'maybe' for 'patient_retry'" in m

  test "permitted boolean values are accepted":
    for b in ["on", "off", "true", "false", "yes", "no", "1", "0",
              "ON", "Off", "True"]:
      let entries = @[("settings", "notify", b, 3)]
      check validateConfig(P, entries) == ""

  test "empty value is reported":
    let entries = @[("provider", "url", "", 4)]
    let m = validateConfig(P, entries)
    check m == P & ":4: empty value for 'url' in [provider]"

  test "whitespace-only value is reported as empty":
    let entries = @[("provider", "url", "   ", 4)]
    let m = validateConfig(P, entries)
    check m == P & ":4: empty value for 'url' in [provider]"

  test "first violation wins (section before key)":
    let entries = @[
      ("foo", "bar", "baz", 3),
      ("settings", "bad", "x", 5),
    ]
    let m = validateConfig(P, entries)
    check m == P & ":3: unknown section [foo]"

  test "auto_update is a permitted settings key":
    let entries = @[("settings", "auto_update", "true", 3)]
    check validateConfig(P, entries) == ""

  test "sandbox_enabled is a permitted settings key":
    let entries = @[("settings", "sandbox_enabled", "off", 3)]
    check validateConfig(P, entries) == ""

  test "patient_retry and patient-retry are permitted settings keys":
    let entries = @[
      ("settings", "patient_retry", "off", 3),
      ("settings", "patient-retry", "on", 4)
    ]
    check validateConfig(P, entries) == ""

  test "bash_path and bash-path are permitted settings keys":
    let entries = @[
      ("settings", "bash_path", "C:\\bash.exe", 3),
      ("settings", "bash-path", "C:\\bash.exe", 4),
    ]
    check validateConfig(P, entries) == ""

  test "model_prefix is a permitted provider key":
    let entries = @[("provider", "model_prefix", "openai/", 4)]
    check validateConfig(P, entries) == ""

  test "family and reasoning and reasonings are permitted provider keys":
    let entries = @[
      ("provider", "family", "glm", 4),
      ("provider", "reasoning", "high", 5),
      ("provider", "reasonings", "low medium high", 6),
    ]
    check validateConfig(P, entries) == ""

suite "config validation: end-to-end exit code":
  var tmp = ""

  setup:
    tmp = getTempDir() / ("3code-cfgval-" & $getCurrentProcessId() & ".ini")

  teardown:
    removeFile(tmp)

  proc runWithConfig(content: string): tuple[output: string, exitCode: int] =
    writeFile(tmp, content)
    # Point 3code at the temp config via an isolated XDG_CONFIG_HOME so it
    # reads only this file. The binary loads ~/.config/3code/config under
    # XDG_CONFIG_HOME, so we place it at <tmpdir>/3code/config.
    let cfgDir = getTempDir() / ("3code-cfgval-xdg-" & $getCurrentProcessId())
    createDir(cfgDir / "3code")
    copyFile(tmp, cfgDir / "3code" / "config")
    defer: removeDir(cfgDir)
    # A prompt argument forces a config load (parseConfigFile) before any
    # turn work; a bad config dies at load with ExitConfig (3). Run in an
    # isolated cwd so the dir lock (acquired before config load) doesn't
    # collide with a real 3code session in the test runner's cwd.
    let workDir = getTempDir() / ("3code-cfgval-cwd-" & $getCurrentProcessId())
    createDir(workDir)
    defer: removeDir(workDir)
    let probe = "XDG_CONFIG_HOME=" & cfgDir.quoteShell & " " &
                binPath().quoteShell & " hi"
    execCmdEx(probe, workingDir = workDir, options = {poUsePath, poStdErrToStdOut})

  test "bad section exits with ExitConfig (3)":
    let r = runWithConfig("[foo]\nbar = \"baz\"\n")
    check r.exitCode == 3
    check "unknown section [foo]" in r.output

  test "bad settings key exits with ExitConfig (3)":
    let r = runWithConfig("[settings]\ncurrent = \"p.m\"\nfoo = \"bar\"\n")
    check r.exitCode == 3
    check "unknown key 'foo' in [settings]" in r.output

  test "bad search engine exits with ExitConfig (3)":
    let r = runWithConfig("[search]\nengine = \"foo\"\n")
    check r.exitCode == 3
    check "unknown search engine 'foo'" in r.output

  test "empty value exits with ExitConfig (3)":
    let r = runWithConfig("[provider]\nname = \"x\"\nurl = \"\"\n")
    check r.exitCode == 3
    check "empty value for 'url'" in r.output

  test "[shortcuts] unknown command rejected":
    let r = runWithConfig("[settings]\ncurrent = \"p.m\"\n\n[shortcuts]\nfoo = \"CtrlC\"\n")
    check r.exitCode == 3
    check "unknown key 'foo' in [shortcuts]" in r.output

  test "[shortcuts] unknown key spec rejected":
    let r = runWithConfig("[settings]\ncurrent = \"p.m\"\n\n[shortcuts]\ncancel = \"MetaX\"\n")
    check r.exitCode == 3
    check "invalid shortcut value" in r.output

suite "config validation: [shortcuts] schema (in-process)":
  const P = "/tmp/cfg-shortcuts.ini"

  test "shortcuts accepted with valid command and key spec":
    let entries = @[
      ("settings", "current", "p.m", 2),
      ("shortcuts", "cancel", "CtrlC", 5),
      ("shortcuts", "clear", "ESC", 6),
      ("shortcuts", "home", "Home", 7),
    ]
    check validateConfig(P, entries) == ""

  test "shortcuts unknown command rejected":
    let entries = @[("settings", "current", "p.m", 2),
                    ("shortcuts", "foo", "CtrlC", 5)]
    let m = validateConfig(P, entries)
    check m == P & ":5: unknown key 'foo' in [shortcuts]"

  test "shortcuts invalid key spec rejected":
    let entries = @[("settings", "current", "p.m", 2),
                    ("shortcuts", "cancel", "MetaX", 5)]
    let m = validateConfig(P, entries)
    check "invalid shortcut value" in m

  test "shortcuts empty value allowed":
    let entries = @[("settings", "current", "p.m", 2),
                    ("shortcuts", "clear", "", 5)]
    check validateConfig(P, entries) == ""
