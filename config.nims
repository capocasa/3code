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

proc hasUnstagedChanges(): bool =
  ## "Unstaged" means compiled sources differ from HEAD, so untracked
  ## files do not count: the windows job stages dlls.zip/dlls in the
  ## workspace before the test phase, and ci_tests.sh's rebuild of the
  ## 3code binary then re-evaluates this probe -- `?? dlls/` used to bake
  ## "-unstaged" into every windows build (the packaged exe is that
  ## rebuild; linux/mac package a pre-test binary, which is why only
  ## windows showed it). Belt and braces: staticExec merges stderr into
  ## its output (poStdErrToStdOut), so only porcelain v1 records count --
  ## two status columns, a space, then the path. A failing git (no repo,
  ## no git) reports no changes, like the old empty-output behavior.
  let r = gorgeEx("git status --porcelain=v1 --untracked-files=no")
  if r.exitCode != 0:
    return false
  for line in r.output.splitLines():
    if line.len >= 3 and line[2] == ' ' and
        line[0] in {' ', 'M', 'A', 'D', 'R', 'C', 'U', '?'} and
        line[1] in {' ', 'M', 'A', 'D', 'R', 'C', 'U', '?'}:
      return true
  return false

proc getVersionString(): string =
  if onTag():
    getNimbleVersion()
  else:
    getNimbleVersion() & "-" &
      gorge("git branch --show-current").strip() &
      "-" & gorge("git rev-parse --short=8 HEAD").strip() &
      (if hasUnstagedChanges(): "-unstaged" else: "")

switch("path", "src")
switch("path", "tests")  # test helpers (tty_expect, stub_helpers, minline_testutils)
switch("d", "ssl")
# Supported loopback HTTP providers (e.g. local inference servers), including
# production builds. Historical define name; non-loopback HTTP stays forbidden.
switch("d", "testPlainHttp")

when defined(android):
  # Termux: Nim's openssl wrapper dlopens libssl.so.3/libcrypto.so.3 at
  # module init, but Android's linker only searches the system lib dirs
  # and the binary's own DT_RUNPATH for dlopen'd libs, never Termux's
  # $PREFIX/lib (Termux packages get a runpath from their clang; the
  # NDK cross toolchain doesn't add one). Bake the Termux lib dir in as
  # RUNPATH so dlopen finds the openssl package's libs. The path is a
  # link-time constant; the linker doesn't check it exists.
  switch("passL", "-Wl,-rpath,/data/data/com.termux/files/usr/lib")

switch("d", "version=" & getVersionString())

when withDir(thisDir(), system.fileExists("config.local.nims")):
  include "config.local.nims"

# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config
