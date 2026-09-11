version       = "0.7.1"
author        = "Carlo Capocasa"
description   = "The economical coding agent. It's so lean you can use it for free!"
license       = "MIT"
srcDir        = "src"
namedBin["threecode"] = "3code"

requires "nim >= 2.0.0"
requires "streamhttp >= 0.4.5"
requires "ttty >= 0.5.0"
requires "unicodedb >= 0.13.0"
requires "tinotify >= 0.1.3"
requires "sandwall >= 0.5.7"
requires "libsha >= 1.0"
requires "zippy >= 0.10"

task test, "Run the test suite via testament (all, or named files)":
  var files: seq[string] = @[]
  for p in commandLineParams:
    if p.len > 0 and p[0] notin {'-'}:
      files.add p
  # Plain Nim tracks all imported/configured inputs, not just source mtimes.
  exec "sh tools/build_binary.sh 3code src/threecode.nim"
  var cmd = "sh tools/test_dispatch.sh " & (if files.len == 0: "all" else: "files")
  for file in files:
    cmd.add " '" & file.replace("'", "'\"'\"'") & "'"
  exec cmd

task docs, "Build HTML manual from docs/manual.md":
  # nim md2html regenerates nimdoc.out.css from nimdoc's built-in default
  # (light theme + visible theme switcher). Our curated dark theme lives
  # in 3code.css and wins by overwriting the generated file.
  # Run from the base project directory: the nested `nim md2html` walks up to
  # find config.nims, which reads threecode.nimble relative to cwd. withDir
  # would break that path resolution.
  exec "nim md2html --docCmd:skip --outdir:docs docs/manual.md"
  mvFile("docs/manual.html", "docs/index.html")
  cpFile("docs/3code.css", "docs/nimdoc.out.css")

task devdocs, "Build developer HTML docs from source":
  # nim doc regenerates nimdoc.out.css and dochack.js from its built-in
  # defaults (light theme + no 3code header). Restore the curated dark CSS
  # and re-append the 3code header block to dochack.js after generating.
  exec "nim doc --project --outdir:docs/dev src/threecode.nim"
  cpFile("docs/dev/3code.css", "docs/dev/nimdoc.out.css")
  exec "cat docs/dev/3code-header.js >> docs/dev/dochack.js"
