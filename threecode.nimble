version       = "0.5.0"
author        = "Carlo Capocasa"
description   = "The economical coding agent. It's so lean you can use it for free!"
license       = "MIT"
srcDir        = "src"
namedBin["threecode"] = "3code"

requires "nim >= 2.0.0"
requires "streamhttp >= 0.4.2"
requires "ttty >= 0.2.0"
requires "unicodedb >= 0.13.0"
requires "tinotify >= 0.1.1"

task test, "Run the test suite via testament (all, or named files)":
  # testament ships with Nim: it runs each test in its own process with
  # isolation and reporting, and parallelizes across tests/ category
  # subdirectories (tty, stream, api, config, shell, core). Megatest is off
  # because our unittest-style tests print to stdout, which megatest would
  # miscompare as expected output. Tests that can't run on a platform
  # self-disable via specs (disabled: "win"); see docs/windows-testing.md.
  #
  # commandLineParams carries nimble's own flags plus any trailing file
  # args; we forward only the non-flag args so `nimble test foo.nim` runs
  # just that file, matching nimble's default runner UX. Nimscript has no
  # PATH lookup or filesystem walk, so the testament-or-fallback choice and
  # the named-files dispatch live in one shell command.
  var files: seq[string] = @[]
  for p in commandLineParams:
    if p.len > 0 and p[0] notin {'-'}:
      files.add p
  exec "sh -c 'if command -v testament >/dev/null 2>&1; then " &
    "testament --print --megatest:off " &
    (if files.len == 0: "all" else: "r " & files.join(" ")) & "; " &
    "else echo \"Warning: testament not found, falling back to sequential run\" >&2; " &
    "for d in tests/*/; do for f in \"$d\"*.nim; do nim c -r --path:src --path:tests \"$f\"; done; done; fi'"

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
