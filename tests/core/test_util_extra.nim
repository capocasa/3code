import std/[os, strutils, unittest]
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

  test "counts UTF-8 codepoints, not bytes":
    check visibleWidth("café") == 4

  test "empty string is zero width":
    check visibleWidth("") == 0

suite "util: wrapAnsi":
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
