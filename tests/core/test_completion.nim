## Tab completion: the `@` path-completion path in `completionFor`.
##
## `@` at the start of a word turns the rest of the word into a path
## fragment completed against the cwd (like a shell). Subdirectories get
## a trailing `/`, results are alphabetical, and the existing `:`-command
## and model/provider completions are unaffected.
import std/[os, strutils, unittest]
import threecode/[config, ui]

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

suite "completionFor: :model provider.model completion":
  var savedProviders: seq[ProviderRec]
  var savedCurrent: string

  setup:
    savedProviders = activeProviders
    savedCurrent = activeCurrent
    activeProviders = @[
      ProviderRec(name: "zai", models: @["glm-5.2", "glm-5.3"]),
      ProviderRec(name: "baseten", models: @["zai-org/GLM-5.2"])]
    activeCurrent = "zai.glm-5.2"

  teardown:
    activeProviders = savedProviders
    activeCurrent = savedCurrent

  test "provider prefix completes to provider.model entries":
    let c = completionFor(":model baseten.")
    check c == @["baseten.glm-5.2"]

  test "current provider's bare models are unaffected":
    let c = completionFor(":model ")
    check "glm-5.2" in c
    check "glm-5.3" in c
    check "baseten.glm-5.2" notin c

  test "dotted model fragment stays a current-provider completion":
    # `glm-5.` is not a provider prefix, so it completes the short
    # names that start with it (the callback list is prefix-filtered
    # by minline, so this returns the provider's models as-is)
    let c = completionFor(":model glm-5.")
    check "glm-5.2" in c
    check "glm-5.3" in c

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
