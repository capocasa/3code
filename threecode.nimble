version       = "0.4.1"
author        = "Carlo Capocasa"
description   = "The economical coding agent. It's so lean you can use it for free!"
license       = "MIT"
srcDir        = "src"
namedBin["threecode"] = "3code"

requires "nim >= 2.0.0"
requires "https://github.com/capocasa/streamhttp >= 0.3.0"
requires "ttty >= 0.2.0"
requires "unicodedb >= 0.13.0"
requires "https://github.com/capocasa/tinotify >= 0.1.0"

task docs, "Build HTML manual from docs/manual.md":
  # nim md2html regenerates nimdoc.out.css from nimdoc's built-in default
  # (light theme + visible theme switcher). Our curated dark theme lives
  # in 3code.css and wins by overwriting the generated file.
  withDir "docs":
    exec "nim md2html --docCmd:skip --outdir:. manual.md"
    mvFile("manual.html", "index.html")
    cpFile("3code.css", "nimdoc.out.css")

task devdocs, "Build developer HTML docs from source":
  # nim doc regenerates nimdoc.out.css and dochack.js from its built-in
  # defaults (light theme + no 3code header). Restore the curated dark CSS
  # and re-append the 3code header block to dochack.js after generating.
  exec "nim doc --project --outdir:docs/dev src/threecode.nim"
  cpFile("docs/dev/3code.css", "docs/dev/nimdoc.out.css")
  exec "cat docs/dev/3code-header.js >> docs/dev/dochack.js"
