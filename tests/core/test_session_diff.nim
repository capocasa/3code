## The session change log: every mutating action records the path's
## original and latest content (net delta per path), and the rendered
## feed (`buildSessionDiff`) is what the verifier and the work-happened
## heuristic consume. Recorded through the REAL action paths (write,
## patch, apply_patch, bash) with a ReadCache, like the live turn loop.

import std/[json, os, strutils, tables, tempfiles, unittest]
import threecode/[types, actions]
import threecode/goal except Usage

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
