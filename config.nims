import std/[os, strutils, strscans]

proc getNimbleVersion(): string =
  let data = readFile("threecode.nimble")
  for line in data.splitLines():
    if scanf(line.strip(), "version$s=$s\"$+\"", result):
      return
  result = "devel"

proc getVersionString(): string =
  if defined(release):
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

