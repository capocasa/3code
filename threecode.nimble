version       = "0.3.5"
author        = "Carlo Capocasa"
description   = "The economical coding agent. It's so lean you can use it for free!"
license       = "MIT"
srcDir        = "src"
namedBin["threecode"] = "3code"

requires "nim >= 2.0.0"
requires "streamhttp >= 0.1.2"

task docs, "Build HTML manual from docs/manual.md":
  withDir "docs":
    exec "nim md2html --docCmd:skip --outdir:. manual.md"
    mvFile("manual.html", "index.html")

task devdocs, "Build developer HTML docs from source":
  exec "nim doc --project --outdir:docs/dev src/threecode.nim"
