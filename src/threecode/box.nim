## `3code sandbox` (alias `3code sb`) - the filesystem sandbox subcommand.
##
## This is the sandwall CLI (`sandwall restrict ...`) folded into 3code so we
## ship one binary instead of two. The bash tool wraps each command as
## `3code sandbox --policy FILE restrict [--ro TMPDIR] -- sh -c
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
## The policy files 3code can activate (the repo `.sandbox` and the
## user file) are read-only inside the sandbox: the parent seeds
## `hiddenRules` with them at startup and resolvePolicy appends the
## same guards to whatever --policy it loads, so no file rule can
## weaken them and they never render in the rule dump. A foreign
## --policy file (standalone box use) is force-added read-only.
## On Landlock a read-only rule under a writable root does not
## subtract write (rules union within a layer), so on Linux a policy
## file inside a writable tree is still writable from inside the
## sandbox; that is accepted.

when defined(posix):
  import std/posix except Time
import std/[os, strutils]
import sandwall
import sandbox

const usage = """
3code sandbox - filesystem sandbox (Landlock/Seatbelt/ACL)

Usage:
  3code sandbox [--policy FILE ...] restrict [RWPATH ...] [--ro ROPATH ...] -- CMD [ARGS ...]

  `3code sb` is a short alias for `3code sandbox`.

  Applies a sandbox allowing full access (read, write, create, delete,
  rename, execute) to the writable paths, read+execute access to the
  read-only paths, and nothing else, then exec()s CMD. CMD and its
  children are confined: writes outside the writable paths fail with
  EACCES.

  With --policy, the writable/read-only sets come from the given
  policy file (relative targets resolve against the project dir: the
  parent of a `.sandbox` file, else cwd). Explicit RWPATH/ROPATH
  args union with the policy sets. The policy file itself is
  read-only inside the sandbox.

  System dirs (/usr, /bin, /lib, /dev/*, etc.) are always read-only so the
  command's binaries, libs, and device nodes stay runnable; --ro adds to
  that set, it does not replace it.

Examples:
  3code sandbox restrict /tmp /home/me/work -- ls -la
  3code sandbox --policy .sandbox restrict -- make test
  3code sandbox restrict . -- make test

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

proc resolvePolicy(a: BoxArgs): tuple[writable, readonly, denied: seq[string];
                   fence: bool] =
  ## Resolve the policy file(s) plus explicit args into the
  ## (writable, readonly, denied) triple. The 3code policy paths ride
  ## the parse as hidden read-only guards; any other --policy file is
  ## force-added read-only. `denied` carries the policy's last-wins
  ## narrowing (a deny under an allowed root); the backend enforces it
  ## on top of the root lists.
  var writable = a.writable
  var readonly = a.readOnly
  var denied: seq[string]
  var hostRules = 0
  if a.policies.len > 0:
    # Exactly one active policy file: 3code passes the repo `.sandbox`
    # when it exists, else the user file. Multiple --policy args are
    # still accepted (concatenated) for standalone box use.
    var texts: seq[string]
    for f in a.policies:
      texts.add(if fileExists(f): readFile(f) else: "")
    # Relative targets resolve against the project dir: the parent of
    # the last `.sandbox` policy file, falling back to cwd. The policy
    # path itself is made absolute first: a relative `.sandbox` would
    # otherwise resolve `./x` targets against the filesystem root.
    let last = absolutePath(a.policies[^1])
    var projectDir = getCurrentDir()
    if last.extractFilename == PolicyFile:
      projectDir = last.parentDir
    var combined = ""
    for t in texts: combined.add t & "\n"
    let pol = parsePolicy(combined, projectDir) &
                (if hiddenRules.len > 0: hiddenRules
                 else: guardRules(projectDir))
    let r = pol.resolve()
    writable.add r.writable
    readonly.add r.readonly
    denied.add r.denied
    hostRules = r.hosts.len
    # The sandboxed command may read its policy but never change it.
    for f in a.policies:
      if fileExists(f): readonly.add absolutePath(f)
  (writable, readonly, denied, hostRules > 0)

proc boxRestrict(args: seq[string]): int =
  ## Parse the `box restrict` args and confine-then-exec. Returns the
  ## process exit code.
  let (a, err) = parseBoxArgs(args)
  if err.len > 0:
    stderr.writeLine(usage)
    stderr.writeLine("\nError: " & err)
    return 2
  let (writable, readOnly, denied, fence) = resolvePolicy(a)
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
  # Network wall: the first host rule in the policy fences egress.
  # The parent (streamexec) runs the wall proxy and tells box where it
  # is via WALL_PROXY_PORT (loopback port) and WALL_PROXY_SOCK (its
  # unix listener, the Linux netns bridge target). Standalone box with
  # host rules but no proxy env fences with no egress at all - correct
  # fail-closed behaviour.
  let wallPort = try: uint16(parseInt(getEnv("WALL_PROXY_PORT", "0")))
                 except ValueError: 0'u16
  let wallSock = getEnv("WALL_PROXY_SOCK", "")

  when defined(windows):
    # Windows cannot confine the current process; restrict() only prepares
    # the token and stamps ACLs. runSandboxed spawns the child with that
    # token and rolls the ACLs back in a defer. fenceNet is ignored: the
    # Windows wall is keyed on the sandwall user's SID and lives on the
    # spawn path (see sandwall wall/winuser.nim).
    try:
      return int(runSandboxed(writable, a.cmd, read = readOnly,
                              denied = denied, inetOk = fence))
    except CatchableError as e:
      stderr.writeLine("3code sandbox: " & e.msg)
      return 127
  else:
    # posix: confine this process, then exec into CMD. Children inherit
    # the domain, so the parent restricting itself before exec is enough.
    #
    # setsid() runs before restrict+exec so CMD lands in its own session
    # and process group. The bash tool signals the whole group on
    # cancel/timeout; without setsid those signals would miss CMD's children.
    discard setsid()
    when defined(linux):
      restrict(writable, read = readOnly, denied = denied,
               fenceNet = fence, proxyPort = wallPort,
               proxySockPath = wallSock)
    else:
      restrict(writable, read = readOnly, denied = denied,
               fenceNet = fence, proxyPort = wallPort)
    try:
      exec(a.cmd)
    except CatchableError as e:
      stderr.writeLine("3code sandbox: " & e.msg)
      return 127

proc boxMain*(args: seq[string]): int =
  ## Entry for the `3code sandbox` subcommand (alias `sb`). `args` is
  ## the full argv after the subcommand name. Global options (--policy)
  ## may precede the verb.
  if args.len == 0 or args[0] == "-h" or args[0] == "--help":
    stdout.writeLine(usage)
    return 0
  var rest = args
  # hoist leading global options
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
