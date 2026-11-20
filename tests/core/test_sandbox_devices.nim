when defined(linux):
  import std/[os, osproc, sequtils, strutils, unittest]

  proc present(p: string): bool =
    ## A device node exists but is no regular file, and os.fileExists
    ## answers S_ISREG only - so the skip guard needs a type-agnostic
    ## existence check or it would skip every run of this suite.
    try: discard getFileInfo(p); true
    except CatchableError: false

  ## A fenced command must not be told it holds device access the fence
  ## denies. Landlock gates open(2) but neither stat(2) nor faccessat(2),
  ## so an ungranted world-writable node like /dev/full used to display
  ## as a live device owned by nobody:nobody (the namespace maps only
  ## the launching user) while `test -r`/`test -w` answered from DAC
  ## alone and printed "rw OK" - with no denial anywhere for the ask
  ## gate to scrape. box.nim now binds a mode-0000 user-owned scratch
  ## file over every ungranted /dev device node (see
  ## maskUngrantedDevices): honest owner columns, failing probes, and
  ## an EACCES the ask flow can redeem with `allow /dev/...` where the
  ## policy floors the path at ask (the grant skips the mask on the
  ## next launch). Baseline and policy-granted nodes stay live, and
  ## pty allocation through /dev/ptmx plus runtime-created slaves must
  ## keep working.
  ##
  ## A run nested under an outer Landlock domain (this suite inside a
  ## fenced session) cannot write the namespace id maps at all; there
  ## the mask degrades with a notice and the old behaviour stands, so
  ## the test asserts the honest degrade instead.

  const binName = "3code"
  proc binPath(): string = getCurrentDir() / binName

  suite "sandbox device honesty":
    test "ungranted device nodes are masked, granted ones stay live":
      if not present("/dev/full") or not present("/dev/ptmx"):
        skip()
      let dir = getTempDir() / ("3code-devmask-" & $getCurrentProcessId())
      createDir(dir / "denied")
      defer: removeDir(dir)
      # The --deny under the writable root is what forces sandwall into
      # the user namespace the device masks ride on.
      let (outp, code) = execCmdEx(binPath().quoteShell & " sandbox restrict " &
        dir.quoteShell & " --deny " & (dir / "denied").quoteShell &
        " -- sh -c 'ls -ln /dev/full; " &
        "test -r /dev/full && echo R-OK || echo R-DENIED; " &
        "test -w /dev/full && echo W-OK || echo W-DENIED; " &
        "head -c1 /dev/full 2>&1; echo head:$?; " &
        "head -c1 /dev/null; echo null:$?; " &
        "head -c1 /dev/zero >/dev/null; echo zero:$?; " &
        "true 3<>/dev/ptmx && echo ptmx-ok; echo chain-end'")
      check code == 0
      if "WITHOUT device-node masking" in outp:
        # Nested or namespace-less host: the degrade notice is the
        # contract (the probes below would lie; do not assert them).
        check "continuing WITHOUT device-node masking" in outp
      else:
        let myUid = execCmdEx("id -u").output.strip
        let lines = outp.splitLines
        # The mask is a regular, user-owned, permission-less file: no
        # char-device column pair, no overflow uid 65534.
        let fullLine = lines.filterIt(it.endsWith("/dev/full"))
        check fullLine.len == 1
        check fullLine[0].startsWith("-")
        check (" " & myUid & " ") in fullLine[0]
        check "R-DENIED" in outp
        check "W-DENIED" in outp
        check "head: '/dev/full' for reading: Permission denied" in outp or
              "head: cannot open '/dev/full'" in outp
        # Baseline devices keep working - /dev/null write, /dev/zero read.
        check lines.anyIt(it.strip == "null:0")
        check lines.anyIt(it.strip == "zero:0")
        # Pty allocation survives: ptmx stays unmasked and the slaves
        # the kernel creates at runtime never met a mask.
        check lines.anyIt(it.strip == "ptmx-ok")
