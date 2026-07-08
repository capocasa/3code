import std/[os, strutils, strscans]

proc getNimbleVersion(): string =
  let data = readFile("threecode.nimble")
  for line in data.splitLines():
    if scanf(line.strip(), "version$s=$s\"$+\"", result):
      return
  result = "devel"

proc onTag(): bool =
  # Exits 0 only when HEAD is exactly a tag; nonzero (empty output) on a
  # branch or nightly. Distinguishes a tagged release from a release-mode
  # nightly build, which both run with -d:release.
  gorgeEx("git describe --tags --exact-match HEAD").exitCode == 0

proc getVersionString(): string =
  if onTag():
    getNimbleVersion()
  else:
    getNimbleVersion() & "-" &
      gorge("git branch --show-current").strip() &
      "-" & gorge("git rev-parse --short=8 HEAD").strip() &
      (if gorge("git status --porcelain=v1").strip() != "": "-unstaged" else: "")

switch("path", "src")
switch("path", "tests")  # test helpers (tty_expect, stub_helpers, minline_testutils)
switch("d", "ssl")
switch("d", "testPlainHttp")

switch("d", "version=" & getVersionString())

when withDir(thisDir(), system.fileExists("config.local.nims")):
  include "config.local.nims"

# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config
