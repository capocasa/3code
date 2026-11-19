## The session change log: every mutating action records the path's
## original and latest content (net delta per path), and the rendered
## feed (`buildSessionDiff`) is what the verifier and the work-happened
## heuristic consume. Recorded through the REAL action paths (write,
## patch, apply_patch, bash) with a ReadCache, like the live turn loop.

import std/[json, os, sets, strutils, tables, tempfiles, times, unittest]
when defined(posix):
  import std/posix
import threecode/[types, actions]
import threecode/goal except Usage
import threecode/[ignore, snap]

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

  test "computeDiff handles large inputs (nimdiff engine, no caps)":
    # The input-size caps retired with the O(n*m) LCS they guarded:
    # nimdiff is linear-space, so over-cap pairs render real hunks now.
    let big = "line\n".repeat(60000)  # 300 KB pair, past the old byte cap
    let d = computeDiff(big, big & "extra\n", "big.txt")
    check "+extra" in d
    check "big.txt" in d
    let many = "x\n".repeat(6000)   # 12 KB pair, past the old line cap
    check "+y" in computeDiff(many, many & "y\n", "tiny.txt")
    check computeDiff("same\n", "same\n", "eq.txt").len == 0

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
      check e.before == "old\n"  # the arm-time snapshot copy: real
                                 # before-bytes, never fabricated
      check e.after == "new\n"
      check "f.txt".absolutePath notin cache.shellTouched
      let d = buildSessionDiff(cache)
      check "-old" in d
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

  test "opaque shell deletion renders a real minus-diff":
    withLogDir proc (dir: string) =
      writeFile("d.txt", "x\ny\n")
      let cache = newReadCache()
      check armManifest(cache, ".")
      discard runAction(act(akBash, cmd = "bash -c 'rm d.txt'"), cache)
      let e = cache.changes["d.txt".absolutePath]
      check e.before == "x\ny\n"  # stored before-bytes
      check e.after == ""
      let d = buildSessionDiff(cache)
      check "-x" in d
      check "-y" in d
      check "deleted via shell" notin d

  test "arm materializes the snapshot; disarm deletes it":
    withLogDir proc (dir: string) =
      writeFile("s.txt", "s\n")
      writeFile("goal.md", "g\n")
      let cache = newReadCache()
      syncManifest(cache, ".", "goal.md", true)
      check fileExists(".3code/snapshot/s.txt")
      check readFile(".3code/snapshot/s.txt") == "s\n"
      syncManifest(cache, ".", "goal.md", false)
      check not dirExists(".3code/snapshot")
      check not cache.manifestArmed

  test "re-arm copies only the delta":
    withLogDir proc (dir: string) =
      writeFile("keep.txt", "k\n")
      writeFile("drop.txt", "d\n")
      let cache = newReadCache()
      check armManifest(cache, ".")
      let keepId = getFileInfo(".3code/snapshot/keep.txt").id
      writeFile("fresh.txt", "f\n")
      removeFile("drop.txt")
      check armManifest(cache, ".")  # re-arm on a stale baseline
      check getFileInfo(".3code/snapshot/keep.txt").id == keepId
      check fileExists(".3code/snapshot/fresh.txt")
      check not fileExists(".3code/snapshot/drop.txt")

  test "a rename folds as one entry, not delete+create":
    withLogDir proc (dir: string) =
      writeFile("old.txt", "same\n")
      let cache = newReadCache()
      check armManifest(cache, ".")
      discard runAction(act(akBash, cmd = "bash -c 'mv old.txt new.txt'"), cache)
      let n = "new.txt".absolutePath
      check n in cache.changes
      check "old.txt".absolutePath notin cache.changes
      check cache.changes[n].before == "same\n"
      check cache.changes[n].after == "same\n"
      check cache.renamedFrom[n] == "old.txt".absolutePath
      let d = buildSessionDiff(cache)
      check "renamed from " in d
      check "old.txt" in d

  test "oversize shell mutation degrades to a name-only line":
    withLogDir proc (dir: string) =
      let cache = newReadCache()
      check armManifest(cache, ".")
      discard runAction(act(akBash,
        cmd = "bash -c 'head -c 2000000 /dev/zero > big.bin'"), cache)
      check cache.changes["big.bin".absolutePath].after == ""
      check "big.bin".absolutePath in cache.shellTouched
      check "content not captured" in buildSessionDiff(cache)

  test "the walk honors the ignore cascade":
    withLogDir proc (dir: string) =
      let oldG = globalIgnoreFile
      globalIgnoreFile = dir / "no-such-nimignore"  # embedded defaults
      defer: globalIgnoreFile = oldG
      writeFile(".gitignore", "secret\ngenerated/\n")
      createDir("generated")
      writeFile("generated/out.txt", "g\n")
      writeFile("secret", "s\n")
      writeFile("plain.txt", "p\n")
      createDir("sub")
      writeFile("sub/.gitignore", "!secret\n")
      writeFile("sub/secret", "ss\n")
      let cache = newReadCache()
      check armManifest(cache, ".")
      check "plain.txt".absolutePath in cache.manifest
      check "secret".absolutePath notin cache.manifest
      check "generated/out.txt".absolutePath notin cache.manifest
      check "sub/secret".absolutePath in cache.manifest  # deeper unignores

  test ".3code/ignore overrides the gitignore and the defaults":
    withLogDir proc (dir: string) =
      let oldG = globalIgnoreFile
      globalIgnoreFile = dir / "no-such-nimignore"
      defer: globalIgnoreFile = oldG
      createDir(".3code")
      writeFile(".3code/ignore", "!node_modules/\nextra/\n")
      createDir("node_modules/pkg")
      writeFile("node_modules/pkg/junk.js", "j\n")
      createDir("extra")
      writeFile("extra/x.txt", "x\n")
      createDir(".git")
      writeFile(".git/config", "c\n")
      let cache = newReadCache()
      check armManifest(cache, ".")
      check "node_modules/pkg/junk.js".absolutePath in cache.manifest
      check "extra/x.txt".absolutePath notin cache.manifest
      check ".git/config".absolutePath notin cache.manifest  # still pruned:
        # a bare-name negation names no subtree, so pruning stands
      check fileExists(".3code/snapshot/node_modules/pkg/junk.js")

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

  test "specials never enter the manifest: a leftover fifo cannot hang the fold":
    ## A fifo in the tree is ordinary debris (the still repo's own test
    ## suite leaves one in build/tests). The fold reads what the walk
    ## records, and opening a fifo read-only blocks until a writer
    ## appears - a recorded fifo bricks the session with no cancel
    ## watcher in sight, so specials must stay out of the walk entirely.
    when defined(posix):
      withLogDir proc (dir: string) =
        writeFile("f.txt", "x\n")
        doAssert posix.mkfifo("pre.pipe".cstring, Mode(0o644)) == 0
        let cache = newReadCache()
        check armManifest(cache, ".")
        check "pre.pipe".absolutePath notin cache.manifest
        discard runAction(act(akBash, cmd = "bash -c 'mkfifo pipe'"), cache)
        check "pipe".absolutePath notin cache.manifest
        check cache.changes.len == 0
    else:
      skip()

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
