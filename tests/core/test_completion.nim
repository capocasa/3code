## Tab completion and the `:provider` discoverability surfaces.
##
## `@` at the start of a word turns the rest of the word into a path
## fragment completed against the cwd (like a shell). Subdirectories get
## a trailing `/`, results are alphabetical, and the existing `:`-command
## and model/provider completions are unaffected. The `:provider` tests
## cover the key-reentry discoverability work: the verb vocabulary in
## the second completion slot and the hint line on the bare listing.
discard """
  action: compile
"""

import std/[json, os, strutils, unittest]
import threecode/[config, minline, types, ui]

## A temp cwd populated with a known tree, restored on scope exit. Each test
## builds its own so the cwd change is live while the test body runs (the
## `suite`/`test` templates defer execution past any setup at registration
## time, so the fixture must be constructed inside the test).
template withTempCwd(body: untyped) =
  block:
    let prev = try: getCurrentDir() except OSError: "/"
    let root = getTempDir() / ("compl_test_" & $getCurrentProcessId())
    if dirExists(root): removeDir(root)
    createDir(root)
    defer:
      try: setCurrentDir(prev) except OSError: discard
      removeDir(root)
    setCurrentDir(root)
    createDir(root / "alpha")
    createDir(root / "beta")
    writeFile(root / "alpha" / "foo.txt", "")
    writeFile(root / "alpha" / "fresh.md", "")
    writeFile(root / "beta" / "one.nim", "")
    writeFile(root / "apple.nim", "")
    body

suite "completionFor: @ path completion":
  test "bare @ lists cwd entries, dirs suffixed with slash":
    withTempCwd:
      let c = completionFor("@")
      check "@alpha/" in c
      check "@beta/" in c
      check "@apple.nim" in c

  test "@ prefix narrows to matching names":
    withTempCwd:
      let c = completionFor("@a")
      check "@alpha/" in c
      check "@apple.nim" in c
      check c.len > 0
      for m in c:
        check m.startsWith("@a")
      check "@beta/" notin c

  test "@<dir>/ descends into the subdirectory":
    withTempCwd:
      let c = completionFor("@alpha/")
      check "@alpha/foo.txt" in c
      check "@alpha/fresh.md" in c
      check c.len > 0
      for m in c:
        check m.startsWith("@alpha/")

  test "@<dir>/<prefix> narrows inside the directory":
    withTempCwd:
      let c = completionFor("@alpha/f")
      check "@alpha/foo.txt" in c
      check "@alpha/fresh.md" in c

  test "results are sorted alphabetically":
    withTempCwd:
      let c = completionFor("@alpha/")
      check c == @["@alpha/foo.txt", "@alpha/fresh.md"]

  test "no matches returns empty":
    withTempCwd:
      check completionFor("@nope").len == 0

  test "completes the @-word when it is not the first word":
    withTempCwd:
      let c = completionFor("explain @a")
      check "@alpha/" in c
      check "@apple.nim" in c

  test "non-@ words and commands are unchanged":
    check ":help" in completionFor(":")

test "pathCompletions against a nonexistent dir returns empty":
  check pathCompletions("definitely-not-here/").len == 0

suite "provider verb discoverability":
  # A user whose key was revoked meets `:provider` before anything
  # else. Both surfaces must teach the verbs: the second completion
  # slot (typing) and the bare listing (exploring).
  var savedProviders: seq[ProviderRec]
  var savedCurrent: string

  setup:
    savedProviders = activeProviders
    savedCurrent = activeCurrent
    activeProviders = @[
      ProviderRec(name: "nvidia", url: "https://integrate.api.nvidia.com/v1",
                  key: "nvapi-x", models: @["openai/gpt-oss-20b"]),
      ProviderRec(name: "zai", url: "https://api.z.ai/v1", key: "k",
                  models: @["glm-5.2"])]
    activeCurrent = "nvidia.openai/gpt-oss-20b"

  teardown:
    activeProviders = savedProviders
    activeCurrent = savedCurrent

  test "second slot offers the verbs before provider names":
    let c = completionFor(":provider ")
    for v in ["add", "edit", "update", "new", "pull", "rm"]:
      check v in c
    check "nvidia" in c
    check "zai" in c
    check c.find("edit") < c.find("nvidia")

  test "a provider named like a verb is not duplicated":
    activeProviders = @[ProviderRec(name: "new", models: @["m"])
                        ] & activeProviders
    var news = 0
    for m in completionFor(":provider "):
      if m == "new": inc news
    check news == 1

  test "verb slot leaves the name slots intact":
    check completionFor(":provider edit ") == @["nvidia", "zai"]
    check completionFor(":provider rm ") == @["nvidia", "zai"]

  test "bare :provider listing names the verbs and the key fix":
    var messages = %* []
    var session = Session()
    var prof = Profile()
    var editor: minline.LineEditor
    let res = handleCommandResult(":provider", messages, session, prof,
                                  editor)
    check res.recognized and res.ok
    check "nvidia" in res.body
    check "verbs: add edit update new pull rm" in res.body
    check "edit <name> re-enters its key or renews a login" in res.body
