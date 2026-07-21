## Filesystem sandbox: parse `.3code/sandbox`, check paths, drive `3code box`.
##
## The sandbox file is a tiny ordered DSL. Each line is a one-char access
## code, a single space, and a path. Lines run top-to-bottom; each
## supersedes the ones above it for the path it names. The access codes:
##
##   .  deny        - no read, no write
##   o  read-only   - read + execute
##   O  writable    - read + write + create + delete + rename
##   0  writable    - (alias: the digit zero, hard to misread)
##
## A blank path means the working directory itself. Relative paths resolve
## against the working directory; absolute paths are used as-is.
##
## The default file created on first run:
##
##   . /
##   O
##
## root is denied, cwd is writable. "Yolo" mode (everything writable) is a
## one-line file: `0 /`. The file is never written by the agent; if the
## agent wants to propose a change it edits a copy the user moves into place.
##
## `loadSandbox` parses the file into a `Sandbox` (an ordered list of
## rules). `resolve` walks the rules into the `(writable, readonly)` pair
## `3code box` consumes, honouring last-wins nesting. `checkPath` answers
## the access for a concrete path for the in-process read/write/patch
## tools.

import std/[os, strutils, tables]

proc resolveRawPath(p: string): string =
  ## Absolute cleaned form of `p`, ~-expanded. Mirrors util.resolvePath
  ## without pulling util (which would create a cycle via types). Empty
  ## for an empty input.
  if p.len == 0: return ""
  var q = p
  if q.startsWith("~"): q = expandTilde(q)
  try: absolutePath(q) except CatchableError: q

type
  AccessKind* = enum
    akDeny = ".", akReadOnly = "o", akWritable = "O"

  Rule* = object
    access*: AccessKind
    path*: string        ## canonical absolute path; "" means cwd

  Sandbox* = object
    rules*: seq[Rule]

## Global sandbox state, loaded once at startup. `active = false` means no
## sandbox file was found/created and bash runs unrestricted (the in-process
## read/write/patch tools still consult `current`, which is empty so they
## allow everything). When `active = true`, bash is wrapped in `3code box`
## and read/write/patch check `current`.
var
  current*: Sandbox
  active*: bool = false
  nimboxExe*: string = ""  ## path to the binary to exec for `box restrict` (this one)

proc findNimbox*(): string =
  ## The nimbox CLI is built into 3code as the `box` subcommand, so the
  ## "nimbox binary" the bash tool re-execs is just this process. Return
  ## its own path; empty only if it can't be resolved (shouldn't happen).
  try:
    result = getAppFilename()
  except CatchableError:
    result = ""

proc backendWorks*(exe: string): bool =
  ## Probe whether the OS-native sandbox backend (Landlock/Seatbelt/ACL)
  ## can actually restrict on this host. Re-execs this binary as
  ## `box restrict <tmpdir> -- true`; success means the kernel applies the
  ## domain. Fails on kernels built without Landlock, runners under a
  ## seccomp filter that blocks the syscall, etc. Callers clear `nimboxExe`
  ## when this returns false so the bash tool falls back to the unconfined
  ## setsid path rather than failing every bash command.
  if exe.len == 0: return false
  let tmp = getTempDir() / ("3code-probe-" & $getCurrentProcessId())
  try:
    if not dirExists(tmp): createDir(tmp)
    let code = execShellCmd(
      quoteShell(exe) & " box restrict " & quoteShell(tmp) & " -- true")
    result = code == 0
  except CatchableError:
    result = false

const
  SandboxDir* = ".3code"
  SandboxFile* = "sandbox"

proc defaultSandboxText*(): string =
  ## The two-line default policy: deny everything under root, then open
  ## the working directory for read+write. Written verbatim on first run.
  ". /\nO\n"

proc sandboxPath*(dir: string): string =
  dir / SandboxDir / SandboxFile

proc sandboxPathInCwd*(): string =
  sandboxPath(getCurrentDir())

proc normalizeSandboxPath*(p: string; cwd: string): string =
  ## Resolve a sandbox path to an absolute, cleaned form. An empty path
  ## (the bare-cwd shorthand) becomes `cwd` itself. Tilde is expanded.
  ## No symlink resolution: the sandbox file is hand-written and the
  ## literal cleaned form is what the user expects to match.
  var q = p.strip
  if q.len == 0: return cwd
  if q.startsWith("~"): q = expandTilde(q)
  try:
    if isAbsolute(q): q.normalizedPath else: (cwd / q).normalizedPath
  except CatchableError:
    q

proc parseSandbox*(text: string; cwd: string): Sandbox =
  ## Parse sandbox DSL text into ordered rules. Blank lines and `#`
  ## comments are skipped. Unrecognised prefixes are skipped with no
  ## error so a half-edited file still loads its valid lines (the
  ## user owns this file and can see what they wrote).
  for raw in text.splitLines:
    let line = raw.strip(leading = true, trailing = false)
    if line.len == 0 or line[0] == '#': continue
    let prefix = line[0]
    let access =
      case prefix
      of '.': akDeny
      of 'o': akReadOnly
      of 'O', '0': akWritable
      else: continue
    # Everything after the prefix and exactly one separating space is the
    # path. Allow no-space (bare `O` for cwd) and tolerate extra spaces.
    var rest = if line.len > 1: line[1 .. ^1] else: ""
    rest = rest.strip(leading = true, trailing = false)
    if rest.len > 0 and rest[0] == ' ':
      rest = rest[1 .. ^1].strip(leading = true, trailing = false)
    result.rules.add Rule(access: access,
                          path: normalizeSandboxPath(rest, cwd))

proc loadSandbox*(path: string): Sandbox =
  ## Read and parse the sandbox file at `path`. Paths in the file resolve
  ## relative to the project dir: the parent of `.3code`. Missing file
  ## yields an empty sandbox (callers decide what that means).
  if not fileExists(path): return Sandbox()
  let projectDir = path.parentDir.parentDir
  let cwd = if projectDir.len > 0: projectDir else: getCurrentDir()
  parseSandbox(readFile(path), cwd)

proc resolve*(s: Sandbox): tuple[writable, readonly: seq[string]] =
  ## Walk the ordered rules into the (writable, readonly) pair `3code box`
  ## consumes. Last-wins per canonical path: a later rule for a path
  ## supersedes every earlier one for that same path. Deny is the
  ## default for anything unmentioned, so deny rules only matter as
  ## overrides of earlier allows; they drop the path from both lists.
  var latest: Table[string, AccessKind]
  var order: seq[string]
  for r in s.rules:
    if r.path notin latest: order.add r.path
    latest[r.path] = r.access
  for p in order:
    case latest[p]
    of akWritable: result.writable.add p
    of akReadOnly: result.readonly.add p
    of akDeny: discard

proc isPathUnder*(path, root: string): bool =
  ## True when `path` equals or is nested under `root` (both expected
  ## cleaned absolute paths). Trailing separators are normalised so
  ## `/a/b` covers `/a/b/sub`. An empty `root` matches nothing.
  if root.len == 0: return false
  if path == root: return true
  let r = if root.endsWith("/"): root else: root & "/"
  path.startsWith(r)

proc checkPath*(s: Sandbox; path: string): AccessKind =
  ## Resolve the effective access for a concrete absolute `path` against
  ## the sandbox policy. Walks the rules in order, so the most specific
  ## applicable rule (the last one whose root covers the path) wins,
  ## matching the top-to-bottom / last-wins semantics of the file.
  ##
  ## Returns `akDeny` when nothing covers the path, which is the safe
  ## default.
  result = akDeny
  for r in s.rules:
    if isPathUnder(path, r.path):
      result = r.access

proc checkRawPath*(path: string; needsWrite: bool): tuple[allowed: bool, reason: string] =
  ## Check a raw (possibly relative) path against the global sandbox.
  ## `needsWrite = false` allows read-only and writable; `true` requires
  ## writable. Returns `(true, "")` when the path is allowed (or when the
  ## sandbox is inactive / the path escapes resolution). Used by the
  ## in-process read/write/patch tools.
  if not active: return (true, "")
  let resolved = resolveRawPath(path)
  if resolved.len == 0: return (true, "")
  let access = current.checkPath(resolved)
  case access
  of akWritable: (true, "")
  of akReadOnly: (not needsWrite, "sandbox: " & resolved & " is read-only")
  of akDeny: (false, "sandbox: " & resolved & " is outside the allowed paths")

proc reload*(projectDir: string) =
  ## Load (or reload) the sandbox file for `projectDir` into the global
  ## `current`. Sets `active = true` when the file exists. `:sandbox`
  ## commands call this after editing so the new policy takes effect on
  ## the next tool call without restarting 3code.
  let path = sandboxPath(projectDir)
  if fileExists(path):
    current = loadSandbox(path)
    active = true

proc ensureDefaultSandbox*(dir: string): bool =
  ## Create the default sandbox file at `dir/.3code/sandbox` if no file
  ## exists there yet. Returns true if a usable sandbox file now exists
  ## (either pre-existing or just created); false if creation failed
  ## (unreadable dir, permission denied, etc.). Callers should refuse
  ## to run in the false case per the spec.
  let path = sandboxPath(dir)
  if fileExists(path): return true
  let sandboxDir = dir / SandboxDir
  try:
    if not dirExists(sandboxDir): createDir(sandboxDir)
    writeFile(path, defaultSandboxText())
  except CatchableError:
    return false
  fileExists(path)

proc renderSandbox*(s: Sandbox): string =
  ## Human-readable dump of the effective rules, newest last (matching
  ## file order). Used by `:sandbox show`.
  if s.rules.len == 0:
    return "(no sandbox rules)"
  for r in s.rules:
    let label =
      case r.access
      of akDeny: "deny   "
      of akReadOnly: "read   "
      of akWritable: "write  "
    let p = if r.path.len == 0: "(cwd)" else: r.path
    result.add label & "  " & p & "\n"

proc appendRule*(sandboxFile, argPath: string; access: AccessKind): bool =
  ## Append a single rule to `sandboxFile`, creating it with the default
  ## contents first if it does not exist. The literal `argPath` is
  ## written as-is so relative paths stay relative and the file stays
  ## portable and human-readable. Returns false on write failure.
  ## Used by `:sandbox allow|deny|readonly`.
  if not fileExists(sandboxFile):
    let projectDir = sandboxFile.parentDir.parentDir
    if not ensureDefaultSandbox(projectDir): return false
  let line = $access & (if argPath.len > 0: " " & argPath else: "") & "\n"
  try:
    var f = open(sandboxFile, fmAppend)
    try: f.write(line) finally: f.close()
  except CatchableError:
    return false
  true
