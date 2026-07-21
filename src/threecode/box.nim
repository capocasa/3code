## `3code box` - the filesystem sandbox subcommand.
##
## This is the nimbox CLI (`nimbox restrict ...`) folded into 3code so we
## ship one binary instead of two. The bash tool wraps each command as
## `3code box restrict <writable> [--ro <readonly>] -- sh -c <script>`: it
## re-execs *itself* (via `getAppFilename`), so there is no PATH lookup and
## no separate nimbox binary to find or bundle. The box process forks,
## setsid()s, applies the OS-native restriction (Landlock/Seatbelt/ACL via
## the `nimbox` library) and exec()s the target; children inherit the
## domain.
##
## Arg parsing mirrors nimbox's CLI verbatim. The only divergence is the
## subcommand name: nimbox's is `restrict`, here `restrict` follows `box`.

when defined(posix):
  import std/posix except Time
import nimbox

const usage = """
3code box - filesystem sandbox (Landlock/Seatbelt/ACL)

Usage:
  3code box restrict RWPATH [RWPATH ...] [--ro ROPATH [ROPATH ...]] -- CMD [ARGS ...]

  Applies a sandbox allowing full access (read, write, create, delete,
  rename, execute) to the RWPATHs, read+execute access to the ROPATHs, and
  nothing else, then exec()s CMD. CMD and its children are confined: writes
  outside the writable paths fail with EACCES.

  System dirs (/usr, /bin, /lib, /etc) are always read-only so the command's
  binaries and libs stay runnable; --ro adds to that set, it does not replace
  it.

Examples:
  3code box restrict /tmp /home/me/work -- ls -la
  3code box restrict /build --ro /secrets -- make test
  3code box restrict . -- make test

Landlock is monotonic: the restriction is permanent for this process and all
descendants. There is no "unrestrict".
  """

proc boxRestrict(args: seq[string]): int =
  ## Parse the `box restrict` args (everything after `box restrict`) and
  ## confine-then-exec. Returns the process exit code.
  if args.len == 0 or args[0] == "-h" or args[0] == "--help":
    stdout.writeLine(usage)
    return 0

  var
    writable: seq[string] = @[]
    readOnly: seq[string] = @[]
    cmd: seq[string] = @[]
    seenSep = false
    seenRo = false

  var i = 0
  while i < args.len:
    let a = args[i]
    if seenSep:
      cmd.add(a)
    elif a == "--":
      seenSep = true
    elif a == "--ro":
      seenRo = true
    elif a == "-h" or a == "--help":
      stdout.writeLine(usage); return 0
    elif seenRo:
      readOnly.add(a)
    else:
      writable.add(a)
    inc i

  if writable.len == 0:
    stderr.writeLine(usage)
    stderr.writeLine("\nError: no writable paths given")
    return 2
  if cmd.len == 0:
    stderr.writeLine(usage)
    stderr.writeLine("\nError: no command given (use -- before the command)")
    return 2

  # System dirs are read-only so the command's binaries and libs are
  # executable but not modifiable. Writable paths come from the user.
  when defined(windows):
    # Windows cannot confine the current process; restrict() only prepares
    # the token and stamps ACLs. runSandboxed spawns the child with that
    # token and rolls the ACLs back in a defer.
    try:
      return int(runSandboxed(writable, cmd, read = readOnly))
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
    when defined(macosx):
      # macOS has no /lib or /lib64; the seatbelt backend already adds the
      # baseline (/usr/lib, /System, /Library, /dev/*) so the dynamic linker
      # works. Just expose the user-facing binary dirs as read-only.
      readOnly.add(["/usr", "/bin", "/sbin", "/etc"])
    else:
      readOnly.add(["/usr", "/bin", "/lib", "/lib64", "/etc"])
    discard setsid()
    restrict(writable, read = readOnly)
    try:
      exec(cmd)
    except CatchableError as e:
      stderr.writeLine("3code box: " & e.msg)
      return 127

proc boxMain*(args: seq[string]): int =
  ## Entry for the `3code box` subcommand. `args` is the full argv after
  ## `box` (i.e. starting at `restrict ...`). Returns the exit code; the
  ## caller quits with it.
  if args.len == 0 or args[0] == "-h" or args[0] == "--help":
    stdout.writeLine(usage)
    return 0
  if args[0] == "restrict":
    return boxRestrict(args[1 .. ^1])
  stderr.writeLine(usage)
  stderr.writeLine("\nError: unknown subcommand (expected 'restrict')")
  return 2
