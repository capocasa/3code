when defined(linux):
  import std/[os, osproc, sequtils, strutils, unittest]

  ## A fenced command must keep the launching user's identity.
  ##
  ## sandwall enters a user+mount namespace for the deny masks and
  ## then writes the namespace's id maps from ids read only AFTER
  ## unshare(2) - when they already show as the unmapped overflow
  ## 65534. The kernel rejects that write, sandwall degrades, and the
  ## confined command used to run stranded in an unmapped namespace:
  ## `id` said nobody while the inherited env said USER=carlo, every
  ## file in a listing read nobody:nobody, and git flagged the repo as
  ## dubious ownership. The mapping is sandwall's to write and only
  ## sandwall's: the kernel binds a /proc id-map file to the task's
  ## user namespace at OPEN time and checks the write against the
  ## opener's credentials, so no wrapper-side fd trick can reach it
  ## (a pre-unshare handle names the immutable initial map; after
  ## restrict() Landlock denies the open outright). sandwall now
  ## reads the ids BEFORE the unshare and self-maps the user onto
  ## themselves; box.nim's repairUsernsIds is the degrade guard that
  ## reports a still-stranded namespace.
  ##
  ## Self-mapping is impossible from inside an already-unmapped
  ## namespace (no id of the outer namespace is expressible there) and
  ## from inside an outer Landlock domain (the map files cannot be
  ## opened for write at all) - a sandboxed run of this suite hits the
  ## latter. Those environments assert the honest-degrade notice
  ## instead, so the test carries information in both.

  const binName = "3code"
  proc binPath(): string = getCurrentDir() / binName

  suite "sandbox userns identity":
    test "restricted command keeps the launching user's id":
      let parentUid = execCmdEx("id -u").output.strip
      let dir = getTempDir() / ("3code-userns-" & $getCurrentProcessId())
      createDir(dir / "denied")
      defer: removeDir(dir)
      # The --deny under the writable root is what forces sandwall into
      # the user namespace at all; without it no namespace is entered
      # and the test would pass vacuously.
      let (outp, code) = execCmdEx(binPath().quoteShell & " sandbox restrict " &
        dir.quoteShell & " --deny " & (dir / "denied").quoteShell &
        " -- sh -c 'id -u; cat /proc/self/uid_map'")
      check code == 0
      # Warnings (sandwall's, the repair's) interleave with the child's
      # stdout in the merged capture, so assert on whole lines, never
      # on positions.
      let lines = outp.splitLines
      # Two environments strand the namespace and must say so: an
      # unmapped outer namespace (parentUid 65534; no outer id is
      # expressible), and a run nested under an outer Landlock domain,
      # where the id-map files cannot be opened for write at all -
      # sandwall's own warning lands before the repair's notice, so
      # branch on the notice, not on a prediction of the environment.
      if "mapping the user namespace failed" in outp:
        check lines.anyIt(it.strip == "65534")
      else:
        check lines.anyIt(it.strip == parentUid)
        # /proc/self/uid_map pads its columns; compare the line with
        # runs of whitespace collapsed, not as a substring.
        check lines.anyIt(it.splitWhitespace.join(" ") ==
          parentUid & " " & parentUid & " 1")
