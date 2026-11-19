## The ignore cascade: parser, matcher, cascade order, and the pruning
## rule, at unit level. Walk-level behavior (what armManifest records)
## lives in test_session_diff.nim.

import std/[os, tempfiles, unittest]
import threecode/[ignore, types]

proc chain(rules: string; scope = ""): seq[IgnoreRule] =
  parseIgnore(rules, scope)

proc bare(rules: string): IgnoreCascade =
  IgnoreCascade(base: @[], final: @[])

suite "ignore parsing":
  test "comments and blanks skip":
    check parseIgnore("# c\n\n   \nfoo\n", "").len == 1

  test "negation, dirOnly, anchoring":
    let r = parseIgnore("!build/keep\nbuild/\n/rooted\na/b\nplain\n", "")
    check r[0].pat.negated and r[0].pat.anchored
    check not r[0].pat.dirOnly  # no trailing slash on the negation
    check r[1].pat.dirOnly and not r[1].pat.anchored
    check r[2].pat.anchored and not r[2].pat.dirOnly
    check r[3].pat.anchored  # an interior slash anchors too
    check not r[4].pat.anchored and not r[4].pat.dirOnly

  test "embedded defaults replace wholesale when the file is absent":
    let old = globalIgnoreFile
    globalIgnoreFile = getTempDir() / "no-such-nimignore"
    defer: globalIgnoreFile = old
    let g = globalRules()
    check g.len == 8
    let c = IgnoreCascade(base: g, final: @[])
    check c.ignored(@[], ".3code/snapshot/f.txt", false)
    check c.ignored(@[], "deep/.git/config", false)
    check not c.ignored(@[], "real.txt", false)

suite "pattern matching":
  let c = bare("")

  test "name patterns match any depth":
    check c.ignored(chain("foo"), "foo", false)
    check c.ignored(chain("foo"), "a/b/foo", false)
    check not c.ignored(chain("foo"), "foobar", false)

  test "dir-only patterns match dirs and their contents, not files":
    check c.ignored(chain("foo/"), "foo", true)
    check not c.ignored(chain("foo/"), "foo", false)
    check c.ignored(chain("foo/"), "foo/bar.txt", false)

  test "anchors hold the scope root":
    check c.ignored(chain("/foo"), "foo", false)
    check not c.ignored(chain("/foo"), "a/foo", false)
    check c.ignored(chain("a/b"), "a/b", false)
    check not c.ignored(chain("a/b"), "x/a/b", false)

  test "globs: star, query, classes, double-star":
    check c.ignored(chain("*.log"), "x/keep.log", false)
    check not c.ignored(chain("*.log"), "x/keep.logs", false)
    check c.ignored(chain("file?.txt"), "file1.txt", false)
    check c.ignored(chain("f[0-9].txt"), "f7.txt", false)
    check not c.ignored(chain("f[0-9].txt"), "fx.txt", false)
    check c.ignored(chain("f[!0-9].txt"), "fx.txt", false)
    check c.ignored(chain("docs/**"), "docs/a/b.md", false)
    check not c.ignored(chain("docs/**"), "docs", false)
    check c.ignored(chain("**/logs"), "a/b/logs", false)

  test "last match wins, negation re-includes":
    check not c.ignored(chain("foo\n!foo"), "foo", false)
    check c.ignored(chain("!foo\nfoo"), "foo", false)

  test "deeper gitignore overrides shallower":
    let ch = chain("*.log") & chain("!keep.log", "sub")
    check not c.ignored(ch, "sub/keep.log", false)
    check c.ignored(ch, "other.log", false)
    check c.ignored(ch, "sub/other.log", false)

suite "cascade tiers":
  test "the final tier beats the base and the chain":
    let c2 = IgnoreCascade(base: chain("node_modules/\n"),
                           final: chain("!node_modules/\n"))
    check not c2.ignored(@[], "node_modules/pkg/junk.js", false)
    # the chain (a deeper gitignore) beats the base tier
    check not c2.ignored(chain("!node_modules/"), "node_modules/x.js", false)
    # the final tier beats the chain
    let c3 = IgnoreCascade(base: @[], final: chain("special/\n"))
    check c3.ignored(chain("!special/"), "special/f.txt", false)

  test "the final tier wins over a deeper gitignore":
    let c2 = IgnoreCascade(base: @[], final: chain("!special\n"))
    let ch = chain("special\n", "deep")
    check not c2.ignored(ch, "deep/special", false)

suite "the pruning rule":
  let c = bare("")

  test "an anchored negation beneath the dir blocks pruning":
    check c.couldReinclude(@[], chain("!build/keep.log"), "build")
    check c.couldReinclude(chain("x/"), chain("!build/**"), "build")
    # a negation scoped inside the dir itself counts as a source too
    check c.couldReinclude(@[], chain("!/keep.log", "build"), "build")

  test "a bare-name negation never blocks pruning":
    check not c.couldReinclude(@[], chain("!keep.log"), "build")

  test "an anchored negation elsewhere does not block pruning":
    check not c.couldReinclude(@[], chain("!other/keep.log"), "build")

suite "newCascade reads .3code/ignore":
  test "the override point loads from the project root":
    let dir = createTempDir("ignore-cascade-", "")
    defer: removeDir(dir)
    createDir(dir / ".3code")
    writeFile(dir / ".3code" / "ignore", "!node_modules/\nextra/\n")
    let c = newCascade(dir)
    check not c.ignored(@[], "node_modules/x.js", false)
    check c.ignored(@[], "extra/x.js", false)

  test "no .3code/ignore means just the base tier":
    let dir = createTempDir("ignore-cascade-", "")
    defer: removeDir(dir)
    let c = newCascade(dir)
    check c.final.len == 0
    check c.base.len == 8
