version       = "0.8.4"
author        = "Carlo Capocasa"
description   = "The economical coding agent. It's so lean you can use it for free!"
license       = "MIT"
srcDir        = "src"
namedBin["threecode"] = "3code"

requires "nim >= 2.0.0"
requires "streamhttp >= 0.5.0"
requires "ttty >= 0.5.0"
requires "unicodedb >= 0.13.0"
requires "tinotify >= 0.1.3"
requires "sandwall >= 0.5.12"
requires "libsha >= 1.0"
requires "zippy >= 0.10"
requires "ws >= 0.6.0"

import std/strutils

# nim md2html emits no table of contents. addPageToc wraps the page body in
# the nimdoc row/sidebar skeleton and fills a pinned left menu with every
# h2-h6 heading (styled via #page-toc in docs/3code.css).
proc stripTags(s: string): string =
  result = ""
  var i = 0
  while i < s.len:
    if s[i] == '<':
      let j = s.find('>', i)
      if j < 0: break
      i = j + 1
    else:
      result.add s[i]
      inc i

proc addPageToc(path: string) =
  let html = readFile(path)
  var entries: seq[tuple[level: int, id, text: string]] = @[]
  var i = 0
  while true:
    let h = html.find("<h", i)
    if h < 0: break
    i = h + 2
    if html.len - h < 10 or html[h + 2] notin {'2'..'6'} or
        html[h + 3] != ' ' or html[h + 4 .. h + 6] != "id=":
      continue
    let idEnd = html.find('"', h + 8)
    let openEnd = html.find('>', h)
    let close = html.find("</h", h)
    if idEnd < 0 or openEnd < 0 or close < 0: continue
    entries.add((ord(html[h + 2]) - ord('0'), html[h + 8 ..< idEnd],
                 stripTags(html[openEnd + 1 ..< close]).strip))
  if entries.len == 0: return
  var menu = "<ul class=\"page-toc-list\">\n<li><a href=\"#" & entries[0].id &
             "\">" & entries[0].text & "</a>"
  var cur = entries[0].level
  for e in entries[1 .. ^1]:
    if e.level > cur:
      for _ in 1 .. e.level - cur: menu.add "<ul>\n<li>"
    elif e.level == cur:
      menu.add "</li>\n<li>"
    else:
      menu.add "</li>\n"
      for _ in 1 .. cur - e.level: menu.add "</ul>\n</li>\n"
      menu.add "<li>"
    cur = e.level
    menu.add "<a href=\"#" & e.id & "\">" & e.text & "</a>"
  menu.add "</li>\n"
  if cur > entries[0].level:
    for _ in 1 .. cur - entries[0].level: menu.add "</ul>\n</li>\n"
  menu.add "</ul>\n"
  let nav = "<div class=\"row\">\n<div class=\"three columns\" id=\"page-toc\">\n" &
            "<div class=\"page-toc-title\">Contents</div>\n" & menu &
            "</div>\n<div class=\"nine columns\" id=\"content\">\n"
  let titleEnd = html.find("</h1>")
  let footer = html.find("<div class=\"twelve-columns footer\">")
  if titleEnd < 0 or footer < 0 or footer < titleEnd: return
  writeFile(path, html[0 .. titleEnd + 4] & "\n" & nav &
            html[titleEnd + 5 ..< footer] & "</div>\n</div>\n" &
            html[footer .. ^1])

task test, "Run the test suite via testament (all, or named files)":
  var files: seq[string] = @[]
  for p in commandLineParams:
    if p.len > 0 and p[0] notin {'-'}:
      files.add p
  if files.len == 0:
    # Full suite through the CI wrapper: testament output goes to a log
    # file, never a reader pipe whose 64KiB buffer backpressures a wedged
    # test into silent infinity (the `nimble test` hang), and a watchdog
    # names and bounds any stall. PER_TEST_SECS=0 by default: local runs
    # share the box with editors and other suites, where the CI 300s
    # per-test cap flakily kills slow-but-healthy tty tests; an ambient
    # PER_TEST_SECS still wins.
    exec "PER_TEST_SECS=${PER_TEST_SECS:-0} sh tests/tools/ci_tests.sh 2400"
  else:
    # Plain Nim tracks all imported/configured inputs, not just source mtimes.
    exec "sh tests/tools/build_binary.sh 3code src/threecode.nim"
    var cmd = "sh tests/tools/test_dispatch.sh files"
    for file in files:
      cmd.add " '" & file.replace("'", "'\"'\"'") & "'"
    exec cmd

task docs, "Build HTML manual, reference, and developer docs":
  # nim md2html regenerates nimdoc.out.css from nimdoc's built-in default
  # (light theme + visible theme switcher). Our curated dark theme lives
  # in 3code.css and wins by overwriting the generated file.
  # Run from the base project directory: the nested `nim md2html` walks up to
  # find config.nims, which reads threecode.nimble relative to cwd. withDir
  # would break that path resolution.
  exec "nim md2html --docCmd:skip --outdir:docs docs/manual.md"
  mvFile("docs/manual.html", "docs/index.html")
  exec "nim md2html --docCmd:skip --outdir:docs docs/reference.md"
  exec "nim md2html --docCmd:skip --outdir:docs docs/plugins.md"
  exec "nim md2html --docCmd:skip --outdir:docs docs/dev.md"
  cpFile("docs/3code.css", "docs/nimdoc.out.css")
  for page in ["index.html", "reference.html", "plugins.html", "dev.html"]:
    addPageToc("docs/" & page)

task devdocs, "Build developer HTML docs from source":
  # NOTE: currently fails on this box. `nim doc` implies `-d:nimdoc`, which
  # flips std/nativesockets to its winlean flavor on Linux; deps that mix
  # std/net with std/posix (streamhttp setsockopt, sandwall sockshim/proxy
  # SocketHandle/SockLen) then fail to typecheck in doc mode only.
  exec "nim doc --project --outdir:docs/dev src/threecode.nim"
  cpFile("docs/dev/3code.css", "docs/dev/nimdoc.out.css")
  exec "cat docs/dev/3code-header.js >> docs/dev/dochack.js"
