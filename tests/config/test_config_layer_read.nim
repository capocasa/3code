## Layered config reads: `tryLoadStateLayers` merge rules and the
## write-back origin filter. The `-c`/`-C` flag semantics live in
## test_config_layers.nim; the binary-level contract in
## tests/core/test_cli_args.nim.

discard """
  targets: "c"
  matrix: ""
"""

import std/[os, options, strutils, tables, times, unittest]
import threecode/[config, types, util]

template saveGlobals(body: untyped) =
  ## The loader and the writer flip process globals; pin the interesting
  ## ones and put the defaults back whatever the body did.
  let (savedCurrent, savedProviders, savedBaseCurrent, savedBaseProviders,
       savedOrigins, savedParams, savedOrigin, savedStreaming,
       savedNotify) = (activeCurrent, activeProviders, baselineCurrent,
    baselineProviders, providerOrigins, activeParams, currentOriginLayer,
    streamingEnabled, notifyEnabled)
  body
  activeCurrent = savedCurrent
  activeProviders = savedProviders
  baselineCurrent = savedBaseCurrent
  baselineProviders = savedBaseProviders
  providerOrigins = savedOrigins
  activeParams = savedParams
  currentOriginLayer = savedOrigin
  streamingEnabled = savedStreaming
  notifyEnabled = savedNotify

suite "config: layered read":
  var tmp: string

  setup:
    tmp = getTempDir() / ("3code-layers-" & $getCurrentProcessId() & "-" &
                          $epochTime().int64)
    createDir(tmp)
    streamingEnabled = true
    notifyEnabled = true

  teardown:
    removeDir(tmp)

  test "settings merge per key across layers":
    writeFile(tmp / "low", "[settings]\nstreaming = \"off\"\n")
    writeFile(tmp / "high", "[settings]\nnotify = \"off\"\n")
    let (_, _, _, err) = tryLoadStateLayers(@[tmp / "low", tmp / "high"])
    check err == ""
    check streamingEnabled == false  # low set it, high silent
    check notifyEnabled == false     # high set it

  test "a later layer wins per settings key":
    writeFile(tmp / "low", "[settings]\nstreaming = \"off\"\n")
    writeFile(tmp / "high", "[settings]\nstreaming = \"on\"\n")
    discard tryLoadStateLayers(@[tmp / "low", tmp / "high"])
    check streamingEnabled == true

  test "current comes from the highest layer that sets it":
    writeFile(tmp / "low", "[settings]\ncurrent = \"low.m\"\n")
    writeFile(tmp / "mid", "[settings]\n")
    writeFile(tmp / "high", "[settings]\ncurrent = \"high.m\"\n")
    let (cur, _, _, err) = tryLoadStateLayers(@[tmp / "low", tmp / "mid",
                                                tmp / "high"])
    check err == ""
    check cur == "high.m"
    check currentOriginLayer == tmp / "high"

  test "a missing later layer leaves the lower current":
    writeFile(tmp / "low", "[settings]\ncurrent = \"low.m\"\n")
    let (cur, _, _, err) = tryLoadStateLayers(@[tmp / "low", tmp / "gone"])
    check err == ""
    check cur == "low.m"
    check currentOriginLayer == tmp / "low"

  test "providers merge by name with key/url inheritance":
    writeFile(tmp / "low", """
[provider]
name = "alpha"
url = "https://low.example/v1"
key = "low-key"
models = "m1 m2"
""")
    writeFile(tmp / "high", """
[provider]
name = "alpha"
models = "m3"
""")
    let (_, provs, _, err) = tryLoadStateLayers(@[tmp / "low", tmp / "high"])
    check err == ""
    check provs.len == 1
    check provs[0].url == "https://low.example/v1"  # inherited
    check provs[0].key == "low-key"                  # inherited
    check provs[0].models == @["m3"]                 # replaced, not merged
    check providerOrigins["alpha"] == tmp / "high"

  test "distinct provider names stack":
    writeFile(tmp / "low", """
[provider]
name = "alpha"
url = "https://a/v1"
key = "k1"
models = "m1"
""")
    writeFile(tmp / "high", """
[provider]
name = "beta"
url = "https://b/v1"
key = "k2"
models = "m2"
""")
    let (_, provs, _, _) = tryLoadStateLayers(@[tmp / "low", tmp / "high"])
    check provs.len == 2
    check provs[0].name == "alpha"
    check provs[1].name == "beta"

  test "params merge per scope and per key":
    writeFile(tmp / "low", """
[params]
provider = "alpha"
temperature = "0.4"
think-back = "turn"
""")
    writeFile(tmp / "high", """
[params]
provider = "alpha"
temperature = "0.9"
max-tokens = "4096"
""")
    discard tryLoadStateLayers(@[tmp / "low", tmp / "high"])
    check activeParams.len == 1
    check activeParams[0].params.temperature.get == 0.9
    check activeParams[0].params.maxTokens.get == 4096
    # low's key kept:
    check activeParams[0].params.thinkBack.get == parseThinkBackMode("turn")

  test "params scopes stay separate":
    writeFile(tmp / "low", """
[params]
provider = "alpha"
temperature = "0.4"

[params]
provider = "alpha"
model = "m2"
temperature = "0.8"
""")
    discard tryLoadStateLayers(@[tmp / "low"])
    check activeParams.len == 2

  test "search, colors and shortcuts merge per key":
    writeFile(tmp / "low", """
[search]
exa-key = "e-low"
engine = "exa"

[colors]
token-bar = "blue"

[shortcuts]
cancel = "CtrlC"
""")
    writeFile(tmp / "high", """
[search]
exa-key = "e-high"
brave-key = "b-high"

[colors]
token-bar = "red"

[shortcuts]
clear = "ESC"
""")
    discard tryLoadStateLayers(@[tmp / "low", tmp / "high"])
    check activeSearchKeys["exa"] == "e-high"
    check activeSearchKeys["brave"] == "b-high"
    check activeSearchKey == "e-high"
    var colorKeys: Table[string, string]
    let (_, _, colors, _) = tryLoadStateLayers(@[tmp / "low", tmp / "high"])
    check colors["token-bar"] == "red"
    check activeShortcuts["cancel"] == "CtrlC"
    check activeShortcuts["clear"] == "ESC"

  test "a malformed layer names its own file":
    writeFile(tmp / "low", "[settings]\ncurrent = \"a.m\"\n")
    writeFile(tmp / "high", "[settings]\nstreaming = \"maybe\"\n")
    let (_, _, _, err) = tryLoadStateLayers(@[tmp / "low", tmp / "high"])
    check err.contains(tmp / "high")
    check err.contains("streaming")

  test "warnings from every layer accumulate":
    writeFile(tmp / "low", "[settings]\nbogus_low = \"x\"\n")
    writeFile(tmp / "high", "[settings]\nbogus_high = \"x\"\n")
    discard tryLoadStateLayers(@[tmp / "low", tmp / "high"])
    var joined = activeConfigWarnings.join("\n")
    check "bogus_low" in joined
    check "bogus_high" in joined

suite "config: layered write-back":
  var tmp: string

  setup:
    tmp = getTempDir() / ("3code-layers-write-" & $getCurrentProcessId() & "-" &
                          $epochTime().int64)
    createDir(tmp)

  teardown:
    removeDir(tmp)

  test "only the write target's providers persist":
    saveGlobals():
      writeFile(tmp / "a", """
[settings]
current = "extra.m9"

[provider]
name = "extra"
url = "https://extra/v1"
key = "k"
models = "m9"
""")
      writeFile(tmp / "b", """
[settings]
current = "alpha.m1"

[provider]
name = "alpha"
url = "https://alpha/v1"
key = "k2"
models = "m1"
""")
      let (cur, provs, _, err) = tryLoadStateLayers(@[tmp / "a", tmp / "b"])
      check err == ""
      check provs.len == 2
      # An in-session addition must persist with them.
      var withAdd = provs
      withAdd.add ProviderRec(name: "gamma", url: "https://gamma/v1",
                              key: "k3", models: @["m7"])
      writeConfigFile(tmp / "b", cur, withAdd)
      let text = readFile(tmp / "b")
      check "alpha" in text
      check "gamma" in text
      check "extra" notin text
      # The foreign layer's current never lands in the target either:
      # the floor (alpha.m1 from b's own disk) wins while it resolves.
      check "current = \"alpha.m1\"" in text

  test "a fresh target never inherits a foreign layer's current":
    saveGlobals():
      writeFile(tmp / "a", """
[settings]
current = "extra.m9"

[provider]
name = "extra"
url = "https://extra/v1"
key = "k"
models = "m9"
""")
      let (cur, provs, _, err) = tryLoadStateLayers(@[tmp / "a"])
      check err == ""
      check cur == "extra.m9"
      writeConfigFile(tmp / "fresh", cur, provs)
      let text = readFile(tmp / "fresh")
      check "current = \"\"" in text
      check "extra" notin text

  test "a foreign edit to the target survives a layered write":
    saveGlobals():
      writeFile(tmp / "b", """
[settings]
current = "alpha.m1"

[provider]
name = "alpha"
url = "https://alpha/v1"
key = "k2"
models = "m1"
""")
      discard tryLoadStateLayers(@[tmp / "b"])
      # Another instance adds a provider to the target on disk.
      writeFile(tmp / "b", """
[settings]
current = "alpha.m1"

[provider]
name = "alpha"
url = "https://alpha/v1"
key = "k2"
models = "m1"

[provider]
name = "delta"
url = "https://delta/v1"
key = "k9"
models = "m5"
""")
      writeConfigFile(tmp / "b", activeCurrent, activeProviders)
      let text = readFile(tmp / "b")
      check "alpha" in text
      check "delta" in text  # foreign addition kept

  test "single-file sessions write verbatim like before":
    saveGlobals():
      writeFile(tmp / "solo", """
[settings]
current = "ghost.m1"

[provider]
name = "alpha"
url = "https://alpha/v1"
key = "k2"
models = "m1"
""")
      discard tryLoadStateLayers(@[tmp / "solo"])
      check providerOrigins.len == 1
      # An unresolvable current in a one-file load still persists
      # (no layered session may rewrite it away).
      writeConfigFile(tmp / "solo", activeCurrent, activeProviders)
      check "current = \"ghost.m1\"" in readFile(tmp / "solo")
