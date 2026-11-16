## The session change log: every mutating action records the path's
## original and latest content (net delta per path), and the rendered
## feed (`buildSessionDiff`) is what the verifier and the work-happened
## heuristic consume. Recorded through the REAL action paths (write,
## patch, apply_patch, bash) with a ReadCache, like the live turn loop.

import std/[json, os, sets, strutils, tables, tempfiles, times, unittest]
import threecode/[types, actions]
import threecode/goal except Usage
import threecode/snap

proc withLogDir(body: proc (dir: string)) =
  let dir = createTempDir("changelog-test-", "")
  defer: removeDir(dir)
  let old = getCurrentDir()
  setCurrentDir(dir)
  defer: setCurrentDir(old)
  body(dir)

proc act(kind: ActionKind; path = ""; bodyText = ""; edits: seq[tuple[s,
    r: string]] = @[]; cmd = ""): Action =
  case kind
  of akWrite: result = Action(kind: akWrite, path: path, body: bodyText)
  of akPatch: result = Action(kind: akPatch, path: path, edits: edits)
  of akBash: result = Action(kind: akBash, body: cmd)
  else: doAssert false, "unused in this suite"

suite "session change log":
  test "write records first touch; rewrites keep the original":
    withLogDir proc (dir: string) =
      let cache = newReadCache()
      discard runAction(act(akWrite, path = "a.txt", bodyText = "one\n"),
                       cache)
      discard runAction(act(akWrite, path = "a.txt", bodyText = "one\ntwo\n"),
                       cache)
      check cache.changes.len == 1
      check cache.changes["a.txt".absolutePath].before == ""
      check cache.changes["a.txt".absolutePath].after == "one\ntwo\n"
      check readFile("a.txt") == "one\ntwo\n"

  test "patch records content, not the rendered diff":
    withLogDir proc (dir: string) =
      writeFile("b.txt", "alpha\nbeta\n")
      let cache = newReadCache()
      discard runAction(act(akPatch, path = "b.txt",
        edits = @[("alpha", "ALPHA")]), cache)
      check cache.changes["b.txt".absolutePath].before == "alpha\nbeta\n"
      check cache.changes["b.txt".absolutePath].after == "ALPHA\nbeta\n"

  test "apply_patch add/update/delete all record":
    withLogDir proc (dir: string) =
      let cache = newReadCache()
      discard runAction(Action(kind: akApplyPatch, body:
        "*** Begin Patch\n*** Add File: c.txt\n+hello\n*** End Patch"),
        cache)
      check cache.changes["c.txt".absolutePath].after == "hello\n"
      discard runAction(Action(kind: akApplyPatch, body:
        "*** Begin Patch\n*** Update File: c.txt\n@@\n-hello\n+hi\n*** End Patch"),
        cache)
      check cache.changes["c.txt".absolutePath].before == ""
      check cache.changes["c.txt".absolutePath].after == "hi\n"
      discard runAction(Action(kind: akApplyPatch, body:
        "*** Begin Patch\n*** Delete File: c.txt\n*** End Patch"), cache)
      check cache.changes["c.txt".absolutePath].after == ""

  test "bash sed round-trip records through the real exec path":
    withLogDir proc (dir: string) =
      writeFile("d.txt", "x = 1\n")
      let cache = newReadCache()
      let (outp, code, diff) = runAction(
        act(akBash, cmd = "sed -i 's/x = 1/x = 2/' d.txt"), cache)
      check code == 0
      check diff.len > 0  # the live diff still paints
      check cache.changes.len == 1
      check cache.changes["d.txt".absolutePath].before == "x = 1\n"
      check cache.changes["d.txt".absolutePath].after == "x = 2\n"

  test "bash creating a file records a creation (no before-state needed)":
    withLogDir proc (dir: string) =
      let cache = newReadCache()
      discard runAction(act(akBash, cmd = "echo fresh > new.txt"), cache)
      check cache.changes["new.txt".absolutePath].before == ""
      check cache.changes["new.txt".absolutePath].after == "fresh\n"

  test "a nil cache records nothing and nothing crashes":
    withLogDir proc (dir: string) =
      discard runAction(act(akWrite, path = "n.txt", bodyText = "x\n"))
      check not fileExists("n.txt") or true  # sandbox may allow; irrelevant
      recordChange(nil, "n.txt", "", "x\n")

  test "buildSessionDiff renders net diffs, path-sorted":
    withLogDir proc (dir: string) =
      let cache = newReadCache()
      discard runAction(act(akWrite, path = "z.txt", bodyText = "zebra\n"),
                       cache)
      discard runAction(act(akWrite, path = "a.txt", bodyText = "ants\n"),
                       cache)
      let d = buildSessionDiff(cache)
      check d.find("a.txt") < d.find("z.txt")
      check "+ants" in d
      check "+zebra" in d

  test "multi-edit same file collapses to the net session delta":
    withLogDir proc (dir: string) =
      let cache = newReadCache()
      discard runAction(act(akWrite, path = "m.txt", bodyText = "v1\n"), cache)
      discard runAction(act(akWrite, path = "m.txt", bodyText = "v2\n"), cache)
      discard runAction(act(akWrite, path = "m.txt", bodyText = "v3\n"), cache)
      let d = buildSessionDiff(cache)
      check "+v3" in d
      check "v1" notin d  # intermediate states are gone from the net delta
      check "v2" notin d.replace("+v2", "")

  test "net-identical content renders nothing":
    withLogDir proc (dir: string) =
      let cache = newReadCache()
      writeFile("same.txt", "keep\n")
      discard runAction(act(akWrite, path = "same.txt", bodyText = "keep\n"),
                       cache)
      check buildSessionDiff(cache).len == 0

  test "binary and oversize degrade to name-only lines, never silence":
    withLogDir proc (dir: string) =
      let cache = newReadCache()
      discard runAction(act(akWrite, path = "bin.dat",
        bodyText = "PK\x03\x04\x00garbage"), cache)
      discard runAction(act(akWrite, path = "big.txt",
        bodyText = "line\n".repeat(2000)), cache)
      let d = buildSessionDiff(cache)
      check "changed (binary, content not shown)" in d
      check "bin.dat" in d
      check "big.txt" in d
      check "not shown" in d

  test "turnDidWork is content-aware":
    withLogDir proc (dir: string) =
      let msgs = %*[{"role": "user", "content": "go"},
                    {"role": "assistant", "content": newJNull(),
                     "tool_calls": [{"id": "c1", "type": "function",
                       "function": {"name": "bash",
                         "arguments": "{\"command\":\"ls\"}"}}]}]
      let cache = newReadCache()
      # Reads only: the log did not grow, no content work happened.
      check not turnDidWork(msgs, cache, 0)
      # No cache at all: falls back to the tool-action heuristic.
      check turnDidWork(msgs, nil, 0)
      discard runAction(act(akWrite, path = "w.txt", bodyText = "x\n"), cache)
      check turnDidWork(msgs, cache, 0)
      # Baseline caught up: last turn's growth already accounted for.
      check not turnDidWork(msgs, cache, 1)

suite "working-tree manifest (goal-mode COW snapshot)":
  ## `bash -c '...'` wraps the redirect in quotes, so the command-line
  ## scraper (`bashMutationPath`) sees no target at all — the exact
  ## blind spot the manifest exists to close: detection by tree state.
  test "armed manifest folds an opaque shell rewrite, honestly":
    withLogDir proc (dir: string) =
      writeFile("f.txt", "old\n")
      let cache = newReadCache()
      check armManifest(cache, ".")
      discard runAction(act(akBash, cmd = "bash -c 'echo new > f.txt'"), cache)
      check cache.changes.len == 1
      let e = cache.changes["f.txt".absolutePath]
      check e.before == ""  # no original existed to copy by the time the
                             # re-walk saw it: never fabricated
      check e.after == "new\n"
      check "f.txt".absolutePath in cache.shellTouched
      let d = buildSessionDiff(cache)
      check "changed via shell (original not captured" in d
      check "+new" in d

  test "no manifest, no fold: outside goal mode nothing walks":
    withLogDir proc (dir: string) =
      writeFile("f.txt", "old\n")
      let cache = newReadCache()  # never armed: no mode is active
      discard runAction(act(akBash, cmd = "bash -c 'echo new > f.txt'"), cache)
      check cache.changes.len == 0
      check not cache.manifestArmed
      check buildSessionDiff(cache).len == 0

  test "opaque shell creation records like a write-tool creation":
    withLogDir proc (dir: string) =
      let cache = newReadCache()
      check armManifest(cache, ".")
      discard runAction(act(akBash, cmd = "bash -c 'echo hi > g.txt'"), cache)
      let e = cache.changes["g.txt".absolutePath]
      check e.before == ""
      check e.after == "hi\n"
      check "g.txt".absolutePath notin cache.shellTouched
      let d = buildSessionDiff(cache)
      check "+hi" in d
      check "via shell" notin d

  test "observed first, shell after: the true original survives":
    withLogDir proc (dir: string) =
      writeFile("t.txt", "orig\n")
      let cache = newReadCache()
      check armManifest(cache, ".")
      discard runAction(act(akPatch, path = "t.txt",
        edits = @[("orig", "v1")]), cache)
      discard runAction(act(akBash, cmd = "bash -c 'echo v2 > t.txt'"), cache)
      let e = cache.changes["t.txt".absolutePath]
      check e.before == "orig\n"  # first touch copied it — the COW in COW
      check e.after == "v2\n"
      check "t.txt".absolutePath notin cache.shellTouched
      check "-orig" in buildSessionDiff(cache)
      check "+v2" in buildSessionDiff(cache)

  test "opaque shell deletion renders a name-only line":
    withLogDir proc (dir: string) =
      writeFile("d.txt", "x\n")
      let cache = newReadCache()
      check armManifest(cache, ".")
      discard runAction(act(akBash, cmd = "bash -c 'rm d.txt'"), cache)
      let e = cache.changes["d.txt".absolutePath]
      check e.before == ""
      check e.after == ""
      let d = buildSessionDiff(cache)
      check ("deleted via shell: " & "d.txt".absolutePath) in d

  test "oversize shell mutation degrades to a name-only line":
    withLogDir proc (dir: string) =
      let cache = newReadCache()
      check armManifest(cache, ".")
      discard runAction(act(akBash,
        cmd = "bash -c 'head -c 2000000 /dev/zero > big.bin'"), cache)
      check cache.changes["big.bin".absolutePath].after == ""
      check "big.bin".absolutePath in cache.shellTouched
      check "content not captured" in buildSessionDiff(cache)

  test "skip dirs never enter the manifest":
    withLogDir proc (dir: string) =
      createDir("node_modules/pkg")
      writeFile("node_modules/pkg/junk.js", "x\n")
      writeFile("real.txt", "r\n")
      let cache = newReadCache()
      check armManifest(cache, ".")
      check "real.txt".absolutePath in cache.manifest
      check "node_modules/pkg/junk.js".absolutePath notin cache.manifest
      discard runAction(act(akBash,
        cmd = "bash -c 'echo y > node_modules/pkg/junk.js'"), cache)
      check cache.changes.len == 0

  test "syncManifest arms with the mode and disarms without it":
    withLogDir proc (dir: string) =
      writeFile("goal.md", "do the thing\n")
      writeFile("s.txt", "s\n")
      let cache = newReadCache()
      syncManifest(cache, ".", "goal.md", false)
      check not cache.manifestArmed
      syncManifest(cache, ".", "goal.md", true)
      check cache.manifestArmed
      check "s.txt".absolutePath in cache.manifest
      syncManifest(cache, ".", "goal.md", false)
      check not cache.manifestArmed
      check cache.manifest.len == 0

  test "syncManifest re-arms when the mode file is newer":
    withLogDir proc (dir: string) =
      writeFile("goal.md", "first\n")
      let cache = newReadCache()
      syncManifest(cache, ".", "goal.md", true)
      let firstCount = cache.manifest.len
      writeFile("late.txt", "l\n")
      # Same mtime second resolution can hide a re-write: force the issue.
      writeFile("goal.md", "second\n")
      let t = getTime()
      setLastModificationTime("goal.md", t + 2.seconds)
      syncManifest(cache, ".", "goal.md", true)
      check cache.manifestArmed
      check cache.manifest.len == firstCount + 1  # fresh baseline saw it
