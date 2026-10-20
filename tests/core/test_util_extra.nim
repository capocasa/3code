import std/[os, sequtils, strutils, unittest]
import threecode/util

suite "util: detectMdHeader":
  test "detects h1":
    let (ok, text) = detectMdHeader("# Hello")
    check ok
    check text == "Hello"

  test "detects h2":
    let (ok, text) = detectMdHeader("## World")
    check ok
    check text == "World"

  test "detects h3":
    let (ok, text) = detectMdHeader("### Section")
    check ok
    check text == "Section"

  test "rejects non-header":
    let (ok, _) = detectMdHeader("just text")
    check not ok

  test "rejects empty string":
    let (ok, _) = detectMdHeader("")
    check not ok

  test "rejects code fence":
    let (ok, _) = detectMdHeader("```bash")
    check not ok

  test "strips leading/trailing whitespace from header text":
    let (_, text) = detectMdHeader("##  Heading  ")
    check text == "Heading"

suite "util: isMdFenceLine":
  test "detects opening fence":
    check isMdFenceLine("```bash")

  test "detects closing fence":
    check isMdFenceLine("```")

  test "detects fence with spaces":
    check isMdFenceLine("  ```nim")

  test "rejects inline code":
    check not isMdFenceLine("some `code` here")

  test "rejects plain text":
    check not isMdFenceLine("not a fence")

suite "util: visibleWidth":
  test "counts ASCII characters":
    check visibleWidth("hello") == 5

  test "OSC 8 spans are zero width":
    check visibleWidth("\x1b]8;;https://foo\x1b\\hi\x1b]8;;\x1b\\") == 2

  test "BEL-terminated OSC is zero width":
    check visibleWidth("\x1b]8;;https://foo\ahi\x1b]8;;\a") == 2

  test "counts UTF-8 codepoints, not bytes":
    check visibleWidth("café") == 4

  test "empty string is zero width":
    check visibleWidth("") == 0

suite "util: wrapAnsi":
  test "wraps hyperlink by visible width, spans stay whole":
    # Golden-free invariants: every row fits the width (the terminal's
    # autowrap is never the row breaker - see the #58 regression below),
    # no OSC span is split across rows, and no visible byte is lost.
    # A URL wider than the width has always broken mid-text at narrow
    # widths; only the app breaks it now, not the terminal.
    let s = "a \x1b]8;;https://foo/bar\x1b\\doc - https://foo/bar\x1b]8;;\x1b\\ b"
    let lines = wrapAnsi(s, 12)
    for l in lines:
      check visibleWidth(l) <= 12
    let denull = proc(x: string): string =
      x.multiReplace(("\x1b]8;;https://foo/bar\x1b\\", ""),
                     ("\x1b]8;;\x1b\\", ""))
        .filterIt(it notin Whitespace).join("")
    # Spaces legitimately move (word-boundary breaks drop one, mid-URL
    # breaks add a row seam); visible characters must not be lost.
    check lines.join("").denull() == s.denull()
    check lines.join("").count("\x1b]8;;https://foo/bar\x1b\\") == 1
    check lines.join("").count("\x1b]8;;\x1b\\") == 1

  test "word wider than the width char-wraps, terminal never does":
    # Regression (#58): an overlong word used to be emitted as one row
    # wider than the terminal, leaving the terminal's autowrap to break
    # it. The app's row model does not count that row, so every wide
    # word drifted screen and model apart: tails erased, output visibly
    # scrolling away mid-stream.
    let lines = wrapAnsi("W".repeat(81), 78)
    check lines == @["W".repeat(78), "W".repeat(3)]
    for l in lines:
      check visibleWidth(l) <= 78

  test "overlong word between words keeps its tail joinable":
    let lines = wrapAnsi("aaa " & "W".repeat(79) & " tail", 78)
    check lines == @["aaa", "W".repeat(78), "W tail"]

  test "word exactly the width stays one row":
    check wrapAnsi("X".repeat(78), 78) == @["X".repeat(78)]

  test "styled overlong word wraps without breaking the escape":
    let w = "\x1b[97m" & "Y".repeat(80) & "\x1b[0m"
    let lines = wrapAnsi(w, 78)
    check lines.len == 2
    check lines[0].startsWith("\x1b[97m")
    check lines[1].endsWith("\x1b[0m")
    for l in lines:
      check visibleWidth(l) <= 78
    check lines.join("").replace("\x1b[97m", "").replace("\x1b[0m", "") ==
      "Y".repeat(80)

  test "wraps long line at word boundary":
    let lines = wrapAnsi("one two three four", 9)
    check lines.len >= 2

  test "short line stays single":
    let lines = wrapAnsi("short", 80)
    check lines.len == 1

  test "zero width returns input as-is":
    let lines = wrapAnsi("hello", 0)
    check lines.len == 1

suite "util: collapseHome":
  test "replaces home prefix with ~":
    # collapseHome strips the home prefix and leading forward slashes; feed
    # a forward-slash path so the assertion is separator-agnostic across
    # platforms (the proc is forward-slash-oriented by design).
    let input = getHomeDir().replace('\\', '/') & "/src/test.nim"
    check collapseHome(input) == "~/src/test.nim"

  test "no home prefix returns unchanged":
    check collapseHome("/tmp/test.nim") == "/tmp/test.nim"

  test "windows separators collapse against getHomeDir":
    let home = getHomeDir()
    if home.len > 0 and {'\\', ':'}.anyIt(it in home):
      check collapseHome(home & "\\foo") == "~/foo"

suite "util: looksLikePath":
  test "detects file with extension":
    check looksLikePath("src/main.nim")

  test "detects absolute path":
    check looksLikePath("/usr/local/bin/tool")

  test "detects dot-slash path":
    check looksLikePath("./build/output")

  test "detects tilde path":
    check looksLikePath("~/config")

  test "rejects plain prose":
    check not looksLikePath("just some text")

  test "rejects empty string":
    check not looksLikePath("")

  test "detects path with multiple extensions":
    check looksLikePath("archive.tar.gz")

suite "util: isMdSepRow":
  test "detects separator row":
    check isMdSepRow("| --- | --- |")

  test "detects alignment markers":
    check isMdSepRow("| :---: | ---: |")

  test "rejects normal row":
    check not isMdSepRow("| a | b |")

  test "rejects empty":
    check not isMdSepRow("")

suite "util: applyInlineMd":
  test "bold markers are removed":
    let r = applyInlineMd("**bold**")
    check "**bold**" notin r
    check "bold" in r

  test "italic markers are removed":
    let r = applyInlineMd("*italic*")
    check "*italic*" notin r
    check "italic" in r

  test "plain text passes through":
    let r = applyInlineMd("hello world")
    check r == "hello world"

  test "backtick markers are removed":
    let r = applyInlineMd("`code`")
    check "`code`" notin r
    check "code" in r

  test "link with url as text renders bare url in an OSC 8 span":
    check applyInlineMd("[https://foo](https://foo)") ==
      "\x1b]8;;https://foo\x1b\\https://foo\x1b]8;;\x1b\\"

  test "link with differing text renders text - url":
    check applyInlineMd("[docs](https://foo)") ==
      "\x1b]8;;https://foo\x1b\\docs - https://foo\x1b]8;;\x1b\\"

  test "link text carries nested inline markdown":
    check applyInlineMd("[**b** x](https://foo)") ==
      "\x1b]8;;https://foo\x1b\\\x1b[1mb\x1b[22m x - https://foo\x1b]8;;\x1b\\"

  test "url underscores and stars stay literal":
    check applyInlineMd("[w](https://en.wiki.org/wiki/Foo_bar*baz)") ==
      "\x1b]8;;https://en.wiki.org/wiki/Foo_bar*baz\x1b\\" &
      "w - https://en.wiki.org/wiki/Foo_bar*baz\x1b]8;;\x1b\\"

  test "url with balanced parens stays whole":
    check applyInlineMd("[x](https://en.wiki.org/wiki/Foo_(bar))") ==
      "\x1b]8;;https://en.wiki.org/wiki/Foo_(bar)\x1b\\" &
      "x - https://en.wiki.org/wiki/Foo_(bar)\x1b]8;;\x1b\\"

  test "mailto links are recognized":
    check applyInlineMd("[a@b](mailto:a@b)") ==
      "\x1b]8;;mailto:a@b\x1b\\a@b - mailto:a@b\x1b]8;;\x1b\\"

  test "non-path targets pass through verbatim":
    check applyInlineMd("[see](#anchor)") == "[see](#anchor)"
    check applyInlineMd("[see](foo:bar)") == "[see](foo:bar)"
    check applyInlineMd("[see](https://foo)") != "[see](https://foo)"

  test "relative file targets link to their file:// URL (#60)":
    let base = "/tmp/proj"
    check applyInlineMd("Created [some-plan.md](some-plan.md).", base) ==
      "Created " & osc8Link("file:///tmp/proj/some-plan.md", "some-plan.md") & "."
    check applyInlineMd("[docs](docs/x.md)", base) ==
      osc8Link("file:///tmp/proj/docs/x.md", "docs - docs/x.md")

  test "absolute and home-relative file targets link without the base":
    check applyInlineMd("[x](/var/log/app.log)", "/tmp/proj") ==
      osc8Link("file:///var/log/app.log", "x - /var/log/app.log")
    check applyInlineMd("[c](~/cfg)", "/tmp/proj").startsWith(
      "\x1b]8;;file://" & getHomeDir())

  test "file targets with spaces stay out (parser stops at the space)":
    check applyInlineMd("[x](my file.txt)", "/tmp") == "[x](my file.txt)"

  test "colon-bearing targets are schemes, never joined onto the base":
    # `foo:bar` is a scheme-shaped target; `C:\cfg` is one only on
    # windows. On posix neither may resolve into a phantom project file.
    check applyInlineMd("[b](foo:bar)", "/tmp") == "[b](foo:bar)"
    check applyInlineMd("[w](C:\\cfg.ini)", "/tmp") == "[w](C:\\cfg.ini)"

  test "malformed link shapes pass through verbatim":
    check applyInlineMd("[see] (https://foo)") == "[see] (https://foo)"
    check applyInlineMd("[no close](https://foo") == "[no close](https://foo"
    check applyInlineMd("[[]](https://foo)") == "[[]](https://foo)"

suite "util: resolvePath":
  test "resolves tilde to home":
    let resolved = resolvePath("~/test.txt")
    check resolved.startsWith(getHomeDir())
    check not resolved.startsWith("~")

  test "absolute path passes through":
    check resolvePath("/usr/bin/nim") == "/usr/bin/nim"

  test "relative path gets resolved to absolute":
    check resolvePath("src/main.nim").isAbsolute

suite "util: connectErrorDetail":
  # nativesockets.getAddrInfo surfaces DNS failures as
  # raiseOSError(osLastError(), gai_strerror(...)), so the message packs a
  # useless OS strerror in front of the real cause (appended as
  # `Additional info: "..."`). connectErrorDetail keeps only the cause.
  test "keeps only the additional-info cause, dropping OS strerror":
    let e = newException(CatchableError, "Resource temporarily unavailable\n" &
      "Additional info: \"Temporary failure in name resolution\"")
    check connectErrorDetail(e) == "Temporary failure in name resolution"

  test "falls back to whole message when no additional info":
    let e = newException(CatchableError, "Something else weird")
    check connectErrorDetail(e) == "Something else weird"
