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

proc versionBranchPart(): string =
  # `-<branch>` on a branch build; empty on a tag. The leading dash lives
  # in the part so the template stays a plain concatenation.
  if onTag(): ""
  else: "-" & gorge("git branch --show-current").strip()

proc versionCommitPart(): string =
  # `-<short8>`; empty on a tag.
  if onTag(): ""
  else: "-" & gorge("git rev-parse --short=8 HEAD").strip()

proc versionStagePart(): string =
  if hasUnstagedChanges(): "-unstaged" else: ""

# The actual version is this template, expanded at compile time. Keep the
# variable names in lockstep with the runtime User-Agent variables in
# prompts.nim (modelUserAgent).
const VersionTemplate = "$version$branch$commit$stage"

proc getVersionString(): string =
  VersionTemplate.multiReplace(
    ("$version", getNimbleVersion()),
    ("$branch", versionBranchPart()),
    ("$commit", versionCommitPart()),
    ("$stage", versionStagePart()))

switch("path", "src")
switch("path", "tests")  # test helpers (tty_expect, stub_helpers, minline_testutils)
switch("d", "ssl")

when defined(staticSsl):
  # Distribution policy: single binary plus OS. Link dynamically
  # against whatever the target OS commonly ships (distro openssl and
  # libc on Linux, UCRT on Windows); bake in only what it never ships
  # (OpenSSL on Windows - and on macOS the system libssl is LibreSSL,
  # a legacy compat fork without the OpenSSL 1.1/3 ABI, so it counts
  # as not shipped). Fully-static builds are unwanted.
  #
  # CI packaging builds (macOS/Windows): link the OpenSSL built by
  # tests/tools/fetch_openssl.sh straight into the binary instead of
  # shipping dylibs/DLLs. Dev and Linux builds stay dynamic (dlopen of
  # the system/bundled libs), which is what they want: distro-patched
  # openssl on Linux, no staging hassle for devs.
  #
  # The three dynlibOverride keys cover Nim's DLL-name canonization
  # (compiler canonDynlibName strips a leading "lib" and truncates at
  # the first '(' or '.'): "ssl"/"crypto" match the libssl.so/dylib
  # spellings, but the Windows alternation names like
  # "(libssl-1_1-x64|...).dll" canonize to the empty string, and the
  # only override key that matches those is one that also canonizes
  # empty ("("). With only --dynlibOverride:ssl the Windows (and the
  # libcrypto half of every) build silently keeps runtime LoadLibrary
  # stubs and links the archives in as dead weight.
  switch("dynlibOverride", "ssl")
  switch("dynlibOverride", "crypto")
  switch("dynlibOverride", "(")
  switch("define", "useOpenssl3")
  let osslDir = getEnv("OPENSSL_STATIC", "openssl-static")
  switch("passL", osslDir & "/lib/libssl.a")
  switch("passL", osslDir & "/lib/libcrypto.a")
  when defined(windows):
    # libcrypto's bss_conn/e_capi objects reference winsock and the cert
    # store; nim's own -l flags come before the archives in the link
    # line, so they must be repeated after them.
    switch("passL", "-lws2_32")
    switch("passL", "-lcrypt32")
    switch("passL", "-ladvapi32")

# Plain http is accepted for local/LAN hosts (see util.plainHttpHost);
# non-local HTTP stays forbidden so keys never cross a public network in
# cleartext. Historical define name kept for the transport tests.
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
# The version parts, separately, so the runtime User-Agent template can
# expose $branch/$commit/$stage as standalone variables.
switch("d", "versionBranch=" & versionBranchPart())
switch("d", "versionCommit=" & versionCommitPart())
switch("d", "versionStage=" & versionStagePart())

when withDir(thisDir(), system.fileExists("config.local.nims")):
  include "config.local.nims"

# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config
