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
import runtime
import sandwall
import sandwall/baseline
import sandbox
import dirsettings

const usage = """
3code sandbox - filesystem sandbox (Landlock/Seatbelt/ACL)

Usage:
  3code sandbox [--policy FILE ...] [--config WALL.CONF] restrict [RWPATH ...] [--ro ROPATH ...] [--deny DENPATH ...] -- CMD [ARGS ...]

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

  --deny paths are unreachable (read and write) even where the policy
  allows their parent: 3code passes the user-owned files whose sandbox
  switches are authoritative so a confined command cannot edit them.
  A --deny under no granted path at all is dropped as already
  unreachable (this also keeps the Linux bind-mask from being raised
  - and, where namespaces are unavailable, its notice printed - for
  entries that could never bite).

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
    denied: seq[string]
    cmd: seq[string]

proc parseBoxArgs(args: seq[string]): tuple[a: BoxArgs, err: string] =
  ## Parse `box restrict` args: global --policy options, explicit paths,
  ## `--` command separator.
  var a: BoxArgs
  var seenSep = false
  var seenRo = false
  var seenDeny = false
  var i = 0
  while i < args.len:
    let arg = args[i]
    if seenSep:
      a.cmd.add(arg)
    elif arg == "--":
      seenSep = true
    elif arg == "--ro":
      seenRo = true
    elif arg == "--deny":
      seenDeny = true
    elif arg == "--policy":
      inc i
      if i >= args.len:
        return (a, "--policy needs a file argument")
      a.policies.add(args[i])
    elif arg == "-h" or arg == "--help":
      stdout.writeLine(usage); quit(0)
    elif arg == "restrict":
      discard  # subcommand marker, already consumed by boxMain
    elif seenDeny:
      a.denied.add(arg)
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
    # the last `.sandbox` policy file, the project owning a
    # `<dir>/.3code/sandbox` store file (the store's parent), falling
    # back to cwd. The policy path itself is made absolute first: a
    # relative `.sandbox` would otherwise resolve `./x` targets against
    # the filesystem root.
    let last = absolutePath(a.policies[^1])
    var projectDir = getCurrentDir()
    if last.extractFilename == PolicyFile:
      let parent = last.parentDir
      # ".sandbox" (bare) has an empty parentDir; that is cwd, not
      # a blank project root that would make ./bar miss the allow.
      if parent.len > 0: projectDir = parent
    elif last.extractFilename == sandbox.UserPolicyFile and
        last.parentDir.splitFile.name == StoreDirName:
      # `<dir>/.3code/sandbox`: the policy's `./` targets belong to
      # `<dir>`, the directory the store sits in, not the store itself.
      # (The user-level `~/.config/3code/sandbox` fails this test on
      # purpose and keeps the cwd fallback.)
      let owner = last.parentDir.parentDir
      if owner.len > 0: projectDir = owner
    # Relative projectDir (".") makes ".\bar" normalize to the same
    # string as the bare allow, so last-wins drops the deny.
    try: projectDir = absolutePath(projectDir)
    except CatchableError: discard
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
  # Explicit --deny args union with the policy's denies: the backends
  # enforce both against the writable roots (mask/Seatbelt/ACL).
  denied.add a.denied
  # A deny is meaningful only where it narrows something the backends
  # would otherwise grant: under a policy root (the Linux bind-mask's
  # job) or under an auto-granted baseline root (Landlock's carve-out).
  # Anywhere else "unmentioned is already denied", and policy-file
  # denies outside every grant are filtered out by resolve() for
  # exactly that reason. The explicit --deny entries used to skip that
  # filter, so the authority denies rode every fenced command as mask
  # requests for paths no grant could reach - on hosts without user
  # namespaces the attempt printed a degrade notice into the fenced
  # command's output. Narrowed keeps enforce identically on all three
  # backends; dropped keeps were unreachable by construction.
  # Cleaned absolute form for the reachability comparison only; the
  # entries themselves pass through unchanged, and no symlink
  # resolution happens here (policy targets match as written).
  proc absNorm(p: string): string =
    try: result = absolutePath(p).normalizedPath
    except CatchableError: result = p
  var kept: seq[string]
  for d in denied:
    let dn = absNorm(d)
    var meaningful = false
    for root in writable:
      if isPathUnder(dn, absNorm(root)): meaningful = true; break
    if not meaningful:
      for root in readonly:
        if isPathUnder(dn, absNorm(root)): meaningful = true; break
    if not meaningful:
      for root in baselineRead:
        if isPathUnder(dn, root): meaningful = true; break
    if not meaningful: continue
    kept.add d
  denied = kept
  (writable, readonly, denied, hostRules > 0)

when defined(linux):
  const
    procSetgroups = "/proc/self/setgroups"
    procGidMap = "/proc/self/gid_map"
    procUidMap = "/proc/self/uid_map"

  type IdmapFds = object
    ## Write handles on the user-namespace id-mapping files, opened
    ## before the restriction lands (see repairUsernsIds).
    setgroups, gidMap, uidMap: cint

  proc openIdmapFds(): IdmapFds =
    ## Open the id-mapping files for writing while no Landlock domain
    ## exists yet: they sit under no writable root, so once the
    ## restriction applies, opening them for write fails with EACCES
    ## and no repair is possible at all. Landlock gates open(2), not
    ## writes through descriptors that were already open - but the
    ## kernel also binds a /proc id-map file to the task's user
    ## namespace AT OPEN TIME, so a handle opened here names the
    ## INITIAL namespace's map, which an unprivileged writer can never
    ## change: the repair below can only DETECT the stranded namespace
    ## and say so. The mapping itself is sandwall's to write (fixed
    ## 0.5.15: read the ids before unshare, self-map the user);
    ## these handles exist so the degrade is reported, not silent.
    ## O_CLOEXEC on all three: they must not leak into the confined
    ## command.
    result = IdmapFds(setgroups: -1, gidMap: -1, uidMap: -1)
    result.setgroups = posix.open(procSetgroups,
        posix.O_WRONLY or posix.O_CLOEXEC, 0.Mode)
    result.gidMap = posix.open(procGidMap,
        posix.O_WRONLY or posix.O_CLOEXEC, 0.Mode)
    result.uidMap = posix.open(procUidMap,
        posix.O_WRONLY or posix.O_CLOEXEC, 0.Mode)

  proc writeAll(fd: cint; s: string): bool =
    if fd < 0: return false
    var i = 0
    while i < s.len:
      let n = posix.write(fd, s[i].unsafeAddr, cint(s.len - i))
      if n < 0: return false
      inc i, n
    true

  proc repairUsernsIds(fds: IdmapFds; outerUid, outerGid: int) =
    ## sandwall enters a user+mount namespace for the deny masks (and
    ## the net fence) but composes the id-mapping writes from ids read
    ## only AFTER unshare(2) - by then they already read as the
    ## unmapped overflow 65534, and the kernel rejects the "0 65534 1"
    ## line (an unprivileged writer may map only its own uid). sandwall
    ## degrades, and the command runs stranded in an UNMAPPED
    ## namespace: every process and file reads as nobody:nobody,
    ## getpwuid finds no home, git flags the repo as dubious ownership,
    ## and `id` contradicts the inherited USER/HOME env - a fenced
    ## agent misreads its own project as foreign-owned. sandwall
    ## (0.5.15) self-maps the user before these fds were even
    ## opened, so this normally finds a mapping and returns. When it
    ## does not (sandwall too old to self-map, a nested run from an
    ## already-unmapped namespace where no outer id is expressible, or
    ## a run nested under an outer Landlock domain that denies the
    ## map-file opens outright), the write through the handles fails
    ## and the command keeps the nobody display - say so and continue
    ## rather than fail the run.
    let mapped = try: readFile(procUidMap)
                 except CatchableError: return
    if mapped.strip.len > 0: return
    discard writeAll(fds.setgroups, "deny\n")
      # one-way switch, usually already denied by sandwall; without a
      # deny an unprivileged gid_map write is rejected outright
    let gidLine = $outerGid & " " & $outerGid & " 1\n"
    let uidLine = $outerUid & " " & $outerUid & " 1\n"
    if not writeAll(fds.gidMap, gidLine) or
        not writeAll(fds.uidMap, uidLine):
      stderr.writeLine("3code sandbox: mapping the user namespace " &
        "failed; commands run as nobody (uid 65534)")

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
  # is via the `[wall]` config file passed as `--config` (loopback port
  # plus its unix listener, the Linux netns bridge target); on Windows
  # the in-process caller fills the same store directly. Standalone box
  # with host rules but no wall config fences with no egress at all -
  # correct fail-closed behaviour.
  let wallPort = try: uint16(parseInt(runtime.get("wall_port")))
                 except ValueError: 0'u16
  let wallSock = runtime.get("wall_sock")

  when defined(windows):
    # Windows cannot confine the current process; restrict() only
    # stamps the sandbox user's ALLOW grants. runSandboxed spawns the
    # child as that user via CreateProcessWithLogonW and rolls the
    # per-run DENY narrowing back in a defer. fenceNet needs no extra
    # work here: the WFP fence installed by `3code setup`
    # blocks the sandbox user's non-loopback egress at the kernel, and
    # the caller points the child at the wall proxy via env for host
    # rules. When the fence is NOT installed, say so instead of
    # pretending (honest degrade posture).
    # Do not call fenceStatus() here: opening the WFP engine is hundreds
    # of ms and the fence is installed once by `3code setup`. The
    # production tool path already warns when the fence is missing.
    try:
      return int(runSandboxed(writable, a.cmd, read = readOnly,
                              denied = denied))
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
      # The real ids while they still read as themselves: inside
      # sandwall's namespace they show as the unmapped overflow 65534,
      # and the repair needs the pre-namespace truth (repairUsernsIds).
      # The mapping files must be opened before restrict() applies the
      # Landlock domain that forbids opening them.
      let outerUid = int(getuid())
      let outerGid = int(getgid())
      let idmaps = openIdmapFds()
      restrict(writable, read = readOnly, denied = denied,
               fenceNet = fence, proxyPort = wallPort,
               proxySockPath = wallSock)
      repairUsernsIds(idmaps, outerUid, outerGid)
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
  var wallConf = ""
  var i = 0
  while i < rest.len:
    if rest[i] == "--policy" and i + 1 < rest.len:
      policies.add(rest[i + 1])
      rest.delete(i + 1)
      rest.delete(i)
    elif rest[i] == "--config" and i + 1 < rest.len:
      wallConf = rest[i + 1]
      rest.delete(i + 1)
      rest.delete(i)
    else:
      inc i
  # The `[wall]` file the sandbox parent writes (loopback proxy port
  # and unix listener). Absent for standalone use: no proxy, fail-closed.
  if wallConf.len > 0:
    discard runtime.loadWallConf(wallConf)
  if rest.len > 0 and rest[0] == "restrict":
    var forwarded: seq[string]
    for p in policies:
      forwarded.add ["--policy", p]
    return boxRestrict(forwarded & rest[1 .. ^1])
  stderr.writeLine(usage)
  stderr.writeLine("\nError: unknown subcommand (expected 'restrict')")
  return 2
