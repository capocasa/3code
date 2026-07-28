## `3code box` - the filesystem sandbox subcommand.
##
## This is the sandwall CLI (`sandwall restrict ...`) folded into 3code so we
## ship one binary instead of two. The bash tool wraps each command as
## `3code box --policy SYS --policy REPO restrict [--ro TMPDIR] -- sh -c
## <script>`: it re-execs *itself* (via `getAppFilename`), so there is no
## PATH lookup and no separate sandwall binary to find or bundle. The box
## process loads the policy files itself, forks, setsid()s, applies the
## OS-native restriction (Landlock/Seatbelt/ACL via the `sandwall` library)
## and exec()s the target; children inherit the domain.
##
## Loading the policy in the box process (rather than receiving resolved
## paths from the parent) means every launch enforces the freshest file
## contents: a policy edit between the parent's last check and the exec
## can only tighten what box applies.
##
## Policy files are force-added to the read-only set so the sandboxed
## command can read its own policy but not change it. On Landlock a
## read-only rule under a writable root does not subtract write (rules
## union within a layer), so on Linux a policy file inside a writable
## tree is still writable from inside the sandbox; box warns on stderr
## in that case. Hard boundaries belong in the system policy, which sits
## under `- /` and is read-only by default.

when defined(posix):
  import std/posix except Time
import std/os
import sandwall

const usage = """
3code box - filesystem sandbox (Landlock/Seatbelt/ACL)

Usage:
  3code box [--policy FILE ...] restrict [RWPATH ...] [--ro ROPATH ...] -- CMD [ARGS ...]

  Applies a sandbox allowing full access (read, write, create, delete,
  rename, execute) to the writable paths, read+execute access to the
  read-only paths, and nothing else, then exec()s CMD. CMD and its
  children are confined: writes outside the writable paths fail with
  EACCES.

  With --policy, the writable/read-only sets come from the given policy
  files (cascaded in order, system first, relative targets resolved
  against the parent of the last file's `.3code` directory). Explicit
  RWPATH/ROPATH args union with the policy sets. Policy files themselves
  are forced read-only inside the sandbox.

  System dirs (/usr, /bin, /lib, /dev/*, etc.) are always read-only so the
  command's binaries, libs, and device nodes stay runnable; --ro adds to
  that set, it does not replace it.

Examples:
  3code box restrict /tmp /home/me/work -- ls -la
  3code box --policy ~/.config/3code/sandbox --policy .3code/sandbox \
    restrict -- make test
  3code box restrict . -- make test

Landlock is monotonic: the restriction is permanent for this process and all
descendants. There is no "unrestrict".
"""

type
  BoxArgs = object
    policies: seq[string]
    writable: seq[string]
    readOnly: seq[string]
    cmd: seq[string]

proc parseBoxArgs(args: seq[string]): tuple[a: BoxArgs, err: string] =
  ## Parse `box restrict` args: global --policy options, explicit paths,
  ## `--` command separator.
  var a: BoxArgs
  var seenSep = false
  var seenRo = false
  var i = 0
  while i < args.len:
    let arg = args[i]
    if seenSep:
      a.cmd.add(arg)
    elif arg == "--":
      seenSep = true
    elif arg == "--ro":
      seenRo = true
    elif arg == "--policy":
      inc i
      if i >= args.len:
        return (a, "--policy needs a file argument")
      a.policies.add(args[i])
    elif arg == "-h" or arg == "--help":
      stdout.writeLine(usage); quit(0)
    elif arg == "restrict":
      discard  # subcommand marker, already consumed by boxMain
    elif seenRo:
      a.readOnly.add(arg)
    else:
      a.writable.add(arg)
    inc i
  (a, "")

proc resolvePolicy(a: BoxArgs): tuple[writable, readonly, denied: seq[string]] =
  ## Resolve the cascaded policy files plus explicit args into the
  ## (writable, readonly, denied) triple. Policy files are force-added
  ## read-only. `denied` carries the policy's last-wins narrowing (a deny
  ## under an allowed root); the backend enforces it on top of the root
  ## lists.
  var writable = a.writable
  var readonly = a.readOnly
  var denied: seq[string]
  if a.policies.len > 0:
    var texts: seq[string]
    for f in a.policies:
      texts.add(if fileExists(f): readFile(f) else: "")
    # Relative targets resolve against the project dir: the parent of the
    # last policy file's `.3code` directory, falling back to cwd.
    let last = a.policies[^1]
    var projectDir = getCurrentDir()
    if last.parentDir.splitPath.tail == PolicyDir:
      projectDir = last.parentDir.parentDir
    var combined = ""
    for t in texts: combined.add t & "\n"
    let pol = parsePolicy(combined, projectDir)
    let r = pol.resolve()
    writable.add r.writable
    readonly.add r.readonly
    denied.add r.denied
    # The sandboxed command may read its policy but never change it.
    for f in a.policies:
      if fileExists(f): readonly.add f
    when defined(linux):
      # Landlock unions rules within a layer, so the read-only force-add
      # above does not subtract write when the file sits under a writable
      # root. Warn so the user knows to move hard boundaries to the
      # system policy.
      for f in a.policies:
        let abs = try: absolutePath(f).normalizedPath
                  except CatchableError: f
        for w in writable:
          if isPathUnder(abs, w):
            stderr.writeLine("3code box: warning: policy file " & abs &
              " is under a writable rule; on Linux the sandboxed command" &
              " can modify it. Put hard boundaries in the system policy" &
              " (outside any writable root).")
            break
  (writable, readonly, denied)

proc boxRestrict(args: seq[string]): int =
  ## Parse the `box restrict` args and confine-then-exec. Returns the
  ## process exit code.
  let (a, err) = parseBoxArgs(args)
  if err.len > 0:
    stderr.writeLine(usage)
    stderr.writeLine("\nError: " & err)
    return 2
  let (writable, readOnly, denied) = resolvePolicy(a)
  if writable.len == 0 and a.policies.len == 0:
    stderr.writeLine(usage)
    stderr.writeLine("\nError: no writable paths given")
    return 2
  if a.cmd.len == 0:
    stderr.writeLine(usage)
    stderr.writeLine("\nError: no command given (use -- before the command)")
    return 2

  # System dirs (/usr, /bin, /lib, /dev/*, etc.) are auto-added as
  # read-only inside each sandwall backend's restrictImpl (baseline.nim),
  # so the command's binaries, libs, and device nodes stay accessible
  # without listing them here.
  when defined(windows):
    # Windows cannot confine the current process; restrict() only prepares
    # the token and stamps ACLs. runSandboxed spawns the child with that
    # token and rolls the ACLs back in a defer.
    try:
      return int(runSandboxed(writable, a.cmd, read = readOnly,
                              denied = denied))
    except CatchableError as e:
      stderr.writeLine("3code box: " & e.msg)
      return 127
  else:
    # posix: confine this process, then exec into CMD. Children inherit
    # the domain, so the parent restricting itself before exec is enough.
    #
    # setsid() runs before restrict+exec so CMD lands in its own session
    # and process group. The bash tool signals the whole group on
    # cancel/timeout; without setsid those signals would miss CMD's children.
    discard setsid()
    restrict(writable, read = readOnly, denied = denied)
    try:
      exec(a.cmd)
    except CatchableError as e:
      stderr.writeLine("3code box: " & e.msg)
      return 127

proc boxMain*(args: seq[string]): int =
  ## Entry for the `3code box` subcommand. `args` is the full argv after
  ## `box`. Global options (--policy) may precede the subcommand.
  if args.len == 0 or args[0] == "-h" or args[0] == "--help":
    stdout.writeLine(usage)
    return 0
  var rest = args
  # hoist leading global options; keep order for the cascade
  var policies: seq[string]
  var i = 0
  while i < rest.len:
    if rest[i] == "--policy" and i + 1 < rest.len:
      policies.add(rest[i + 1])
      rest.delete(i + 1)
      rest.delete(i)
    else:
      inc i
  if rest.len > 0 and rest[0] == "restrict":
    var forwarded: seq[string]
    for p in policies:
      forwarded.add ["--policy", p]
    return boxRestrict(forwarded & rest[1 .. ^1])
  stderr.writeLine(usage)
  stderr.writeLine("\nError: unknown subcommand (expected 'restrict')")
  return 2
