## Session persistence in the human-readable `.3log` format.
##
## `.3log` is an append-friendly, diff-friendly flat-text format. Each record
## is a header line (role and space-separated args) followed by body lines
## indented two spaces. The format is both the on-disk representation and the
## session audit trail - readable without tooling and diffable in git.
##
## The system prompt is not persisted: it changes too rarely for the bytes
## to earn a place in every session file. The file carries the dynamic
## inputs instead - the discovered skills catalog that was substituted into
## it - plus the identity stamp of the profile that built it, and
## `refreshSystemPrompt` reconstructs the exact bytes from the profile on
## resume.
##
## Cache-parity contract: the message array `loadSessionFile` reconstructs
## re-sends the bytes the live session would. Everything past the system
## prompt round-trips byte-identically: bodies round-trip through the record
## codec without loss, tool_calls carry their original wire JSON, and user
## preambles split and rejoin on the exact grammar `sessionPreamble` emits.
## The system prompt itself is rebuilt from the profile substituting the
## persisted skills catalog, which reproduces the live bytes whenever the
## identity stamp still matches the profile. A resumed turn hits the
## provider's prompt cache exactly like the live session's next turn would.
##
## On load, the full OpenAI-shape `messages` JsonNode array is reconstructed
## from the records so the session can be resumed mid-conversation with no loss.

import std/[algorithm, json, os, strutils, tables, times, tempfiles, sha1]
when defined(posix):
  import std/posix
when defined(windows):
  import std/[widestrs, winlean]
import types, prompts, util, actions

const SessionExt* = ".3log"

# ---------------------------------------------------------------------------
# Session storage: human-readable indented-records.
#
# A session.3log is an append-of-records text file. Each record is a header
# line at column 0, followed by zero or more body lines indented exactly two
# spaces. A `~~` terminator closes a body that ends in a newline; blank
# lines below a terminator visually separate records. Bodies round-trip
# byte-exactly: what was sent on the wire is what a resume re-sends.
#
#   header := role [' ' arg]*
#   arg    := positional | key=value | +flag[=value]
#   body   := ('  ' line '\n')* ['~~\n']
#
# Roles:
#   session     - one per file, top of the file. Created stamp + profile + cwd
#                 (+ prompt_identity, the cache stamp of the profile that
#                 built the conversation's system prompt).
#   skills      - the discovered skills catalog substituted into the system
#                 prompt: the dynamic input, persisted so the resume-time
#                 rebuild reproduces the live prompt bytes. The prompt
#                 itself is constructed from the profile, never stored.
#   system      - legacy: a system prompt persisted verbatim by older
#                 3code. Parsed for wire shape; resume still reconstructs.
#   user        - user input (body = message text).
#   reasoning   - merges into the next assistant's reasoning_content.
#   assistant   - assistant text content (body). Followed by zero or more
#                 tool_use records that join its tool_calls, optionally
#                 closed by a tokens record carrying usage.
#   tool_use    - one per tool call. Header: id, tool name, optional path.
#                 Body holds command / file body / patch text using
#                 `-- name --` section markers when a tool needs more
#                 than one section.
#   tool_result - one per tool response. Header: id, exit=N, optional flags.
#                 Body is the merged stdout/stderr returned to the model.
#   tokens      - per-callModel token usage. Header-only, no body.
# ---------------------------------------------------------------------------

const Roles = ["session", "skills", "system", "context", "project_notes",
               "user", "reasoning", "assistant",
               "tool_use", "tool_result", "tokens"]

# ---------- paths ----------

proc sessionDir*(): string =
  userDataRoot() / "sessions"

proc sessionIdFromPath*(path: string): string =
  let name = path.extractFilename
  if name.endsWith(SessionExt): name[0 ..< name.len - SessionExt.len] else: name

proc newSessionPath*(): string =
  let stamp = now().format("yyyyMMdd'T'HHmmss")
  createDir(sessionDir())
  var n = 0
  while true:
    let id = if n == 0: stamp else: stamp & "-" & $n
    let path = sessionDir() / (id & SessionExt)
    # O_EXCL makes the claim atomic; the counter is the tie-breaker when two
    # processes race for the same second.
    when defined(posix):
      let fd = open(path.cstring, O_WRONLY or O_CREAT or O_EXCL, 0o644)
      if fd >= 0:
        discard close(fd)
        return path
    else:
      if not fileExists(path):
        writeFile(path, "")
        return path
    inc n

# ---------------------------------------------------------------------------
# Cwd path mangling.
#
# `--resume` with no id needs the latest session for the *current* working
# directory, but we refuse to parse every `.3log` to find it (see the cwd
# index below). The index keeps one append-only file per cwd, named by the
# mangled path so the filesystem narrows the lookup for us.
#
# The mapping must be collision-free: `/a/my_project` and `/a/my/project` are
# distinct cwds and must not share an index file. A naive `/`→`_` collapses
# them. We escape existing underscores first (`_`→`__`) and *then* turn
# separators into single underscores, so every original `_` survives as two
# and the common case stays readable:
#
#   "/home/carlo/p/3code/myworktree" → "home_carlo_p_3code_myworktree"
#   "/home/carlo_p"                  → "home_carlo__p"   (distinct from above)
#
# This direction only (cwd→name); nothing needs to invert it, so there's no
# `unmangleCwd` to keep in sync.
# ---------------------------------------------------------------------------

proc mangleCwd*(cwd: string): string =
  var s = cwd.replace('\\', '/')   # normalize backslashes (posix focus)
  if s.startsWith("/"): s = s[1 ..< s.len]
  s = s.replace("_", "__")         # escape existing underscores
  s = s.replace("/", "_")         # then separators → single underscore
  when defined(windows):
    s = s.replace(":", "_")       # drive letter colon (C:)
  if s.len == 0: s = "root"       # cwd "/" (and "") collapse to a stable name
  s

# ---------------------------------------------------------------------------
# Cwd index: an append-only file per cwd listing session ids (timestamps).
#
# Powers resume-latest and `:sessions`/`--list` for a cwd without ever
# reading a session body. The file is append-only, so the last line is the
# latest session; `indexIdsAt` returns ids latest-first.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Per-directory sticky current: the `provider.model` a directory last used.
#
# The global config keeps one `current` for everywhere else; this override
# makes `:provider` / `:model` stick per project, keyed by the same
# collision-free mangled cwd as the session index and drafts.
# ---------------------------------------------------------------------------

proc dirCurrentPathFor*(cwd: string): string =
  userDataRoot() / "dirs" / (mangleCwd(cwd) & ".current")

proc loadDirCurrent*(cwd: string): string =
  ## The sticky `provider.model` for this directory, "" when unset or blank.
  let path = dirCurrentPathFor(cwd)
  if not fileExists(path): return ""
  readFile(path).strip

proc saveDirCurrent*(cwd, current: string) =
  ## Atomically record `current` for this directory (temp + rename, same
  ## scheme as drafts), so a crash mid-write never leaves it truncated.
  let path = dirCurrentPathFor(cwd)
  createDir(path.parentDir)
  let tmp = path & ".tmp"
  writeFile(tmp, current & "\n")
  moveFile(tmp, path)

proc sessionPathIndexDir*(): string =
  userDataRoot() / "session-paths"

func indexPathAt*(indexDir, cwd: string): string =
  indexDir / mangleCwd(cwd)

proc appendIndexAt*(indexDir, cwd, id: string) =
  ## Append `id` to the cwd's index file. Silent on failure: a missing index
  ## entry only means the session won't show in resume-latest, never a crash.
  if indexDir == "" or id == "": return
  let path = indexPathAt(indexDir, cwd)
  try:
    createDir(path.parentDir)
    let f = open(path, fmAppend)
    f.writeLine(id)
    defer: f.close()
  except CatchableError: discard

proc indexIdsAt*(indexDir, cwd: string): seq[string] =
  ## Session ids for `cwd`, latest-first. Reads the single small index file
  ## (one line per session) — never touches a `.3log`.
  if indexDir == "": return
  let path = indexPathAt(indexDir, cwd)
  let raw = try: readFile(path) except CatchableError: return
  for line in splitLines(raw):
    let id = line.strip
    if id.len > 0: result.add id
  result.reverse()   # append order is oldest-first → flip to latest-first

proc appendSessionIndex*(cwd, id: string) =
  appendIndexAt(sessionPathIndexDir(), cwd, id)

# ---------------------------------------------------------------------------
# Prompt drafts.
#
# The text a user is currently typing in the prompt editor is not part of the
# `.3log` transcript (it isn't a committed message yet) but losing it on an
# unexpected shutdown — kill, power-off, Ctrl-C, SIGTERM — is exactly what a
# draft is for. Keeping it out of the `.3log` means the audit transcript stays
# clean and the draft can never be mistaken for a real user turn.
#
# Two scopes, chosen by whether the `.3log` has committed content (allocation
# reserves an empty file; the first turn saves content in turns.nim):
#
#   * Pending (pre-first-turn): `drafts/pending/<cwd-hash>.prompt`. The reserved
#     `.3log` is still empty. The draft is keyed
#     by the working directory instead and loads into the next fresh session
#     started in that directory. This is the "typed a prompt, got killed
#     before sending" case.
#   * Session (post-first-turn): `drafts/<sessionId>.prompt`. The `.3log`
#     exists, so the draft is keyed by session id and restored on resume.
#
# Both are plain UTF-8 written atomically (temp + rename) on a debounce while
# editing, and removed when the prompt is committed.

proc draftDir*(): string =
  userDataRoot() / "drafts"

proc draftPathFor*(sessionPath: string): string =
  draftDir() / (sessionIdFromPath(sessionPath) & ".prompt")

proc pendingDraftDir*(): string =
  draftDir() / "pending"

proc pendingDraftPathFor*(cwd: string): string =
  ## The pre-first-turn draft for a working directory. Keyed by the
  ## collision-free mangled cwd (same scheme as the cwd session index) so
  ## distinct directories never share a draft. One per directory: a singleton,
  ## overwritten as the user edits.
  pendingDraftDir() / (mangleCwd(cwd) & ".prompt")

proc hasSavedSession(path: string): bool =
  path.len > 0 and fileExists(path) and getFileSize(path) > 0

proc currentDraftPath*(session: Session): string =
  ## The draft path for the live session: id-keyed once a `.3log` has content
  ## (post-first-turn), otherwise the cwd-keyed pending path. This is the
  ## single decision point for which scope a draft lives in.
  if hasSavedSession(session.savePath):
    draftPathFor(session.savePath)
  else:
    pendingDraftPathFor(session.cwd)

# ---------------------------------------------------------------------------
# Session locks.
#
# A live 3code process owns its session: resuming one that's already open in
# another process would interleave two writers and corrupt the transcript.
# Each process holds a lock file in TMPDIR/3code/lock/<id>.lock for the
# session it's editing.
#
# Acquiring a lock is atomic on both platforms: POSIX uses open(O_CREAT|O_EXCL)
# and Windows uses CreateFileW(CREATE_NEW), so two racers can't both grab one.
# On collision we read the holding lock's pid; if that process is no longer
# alive (the common case after a crash or killed 3code) the stale lock is
# removed automatically and acquisition retries once. Only when the holder is
# still genuinely running does acquire raise SessionLocked. The currently-held
# lock path is tracked in a module global so an exit proc can release whatever
# the process most recently held (it moves with :clear forks).

var activeLockPath* = ""

proc sessionLockDir*(): string =
  tempDir() / "3code" / "lock"

proc sessionLockPathFor*(path: string): string =
  # Resolve existing symlinks, including a symlinked data root. New explicit
  # output paths may not exist yet, but their parent normally does.
  let identity =
    if fileExists(path): expandFilename(path)
    elif dirExists(path.absolutePath.parentDir):
      expandFilename(path.absolutePath.parentDir) / path.extractFilename
    else: normalizedPath(absolutePath(path))
  sessionLockDir() / ($secureHash(identity) & ".lock")

type SessionLocked* = object of CatchableError

# Windows access rights/disposition constants used by the atomic lock create.
# Guarded so they (and winlean) only participate in a Windows build; on POSIX
# they'd otherwise show as unused and pull in the windows modules for nothing.
when defined(windows):
  const
    WingenGenericWrite = 0x40000000'i32
    WinCreateNew = 1'i32
    WinFileAttributeNormal = 0x00000080'i32

proc writeOwnerInfo(fd: int; data: string) =
  ## Write the owner record into a freshly created lock file: the pid line,
  ## plus (dir locks) a second line carrying the holder's session id so a
  ## collision report can name the session, not just the process.
  when defined(posix):
    if data.len > 0:
      discard write(cint(fd), data.cstring, data.len)
  else:
    var written: int32 = 0
    if data.len > 0:
      discard writeFile(fd, data.cstring, int32 data.len, addr written, nil)

proc tryCreateLockFile(lockPath: string; pid: string): int =
  ## Atomically create `lockPath` and write `pid` into it.
  ##
  ## Returns a handle/fd that the caller closes on success, or -1 if the file
  ## already exists (collision — caller decides whether the holder is live).
  ## Any other failure raises SessionLocked.
  when defined(posix):
    let p = lockPath.cstring
    let fd = open(p, O_WRONLY or O_CREAT or O_EXCL, 0o600.cint)
    if fd < 0:
      let errno = osLastError()
      if errno.int32 == EEXIST.int32: return -1
      raise newException(SessionLocked,
        "could not create session lock " & lockPath & ": " & osErrorMsg(errno))
    writeOwnerInfo(fd, pid)
    discard close(fd)
    0
  else:
    let h = winlean.createFileW(newWideCString(lockPath),
                                WingenGenericWrite, 0'i32, nil,
                                WinCreateNew, WinFileAttributeNormal, 0)
    if h == INVALID_HANDLE_VALUE:
      let errno = osLastError()
      # ERROR_FILE_EXISTS (80) / ERROR_ALREADY_EXISTS (183) -> expected collision.
      if errno.int32 == 80'i32 or errno.int32 == 183'i32: return -1
      raise newException(SessionLocked,
        "could not create session lock " & lockPath & ": " & osErrorMsg(errno))
    writeOwnerInfo(h, pid)
    discard winlean.closeHandle(h)
    0

proc readOwnerPid(lockPath: string): string =
  ## First line of the lock file (the pid). Dir locks carry a second line
  ## (the holder's session id) that must not leak into the int parse.
  try: readFile(lockPath).strip.splitLines[0].strip except CatchableError: ""

proc readOwnerSessionId(lockPath: string): string =
  let lines = try: readFile(lockPath).strip.splitLines except CatchableError: @[]
  if lines.len > 1: lines[1].strip else: ""

proc lockHeldError(path, lockPath, owner: string): ref SessionLocked =
  var mtime = getTime()
  try: mtime = getLastModificationTime(lockPath) except OSError: discard
  newException(SessionLocked,
    "session \"" & sessionIdFromPath(path) & "\" is already open" &
    (if owner.len > 0: " (pid " & owner & ")" else: "") &
    " in another running 3code process. Lock file: " & lockPath &
    " (last modified " & format(mtime.local, "yyyy-MM-dd HH:mm:ss") & ")." &
    " If no 3code is running, the lock is stale and the pid check failed —" &
    " delete it: " & lockPath)

proc acquireSessionLock*(path: string) =
  ## Atomically claim the lock for `path`.
  ##
  ## If a lock exists but its owner process is no longer alive, it's treated
  ## as stale (left behind by a crash) and removed automatically, then
  ## acquisition retries once. Raises SessionLocked only when another live
  ## 3code process genuinely holds the lock (or a second racer grabbed it in
  ## the retry window).
  if path == "": return
  let dir = sessionLockDir()
  try: createDir(dir) except OSError: discard
  let lockPath = sessionLockPathFor(path)
  let pid = $getCurrentProcessId()
  for attempt in 0 .. 1:
    if tryCreateLockFile(lockPath, pid) >= 0:
      activeLockPath = lockPath
      return
    # Collision: an existing lock is in the way. Decide stale-vs-live.
    let owner = readOwnerPid(lockPath)
    var ownerPid = -1
    try: ownerPid = parseInt(owner) except ValueError: discard
    if ownerPid > 0 and pidAlive(ownerPid):
      # The holder is genuinely running. Refuse rather than corrupt it.
      raise lockHeldError(path, lockPath, owner)
    # Stale (dead owner, or corrupt/unparseable pid): reclaim and retry once.
    try: removeFile(lockPath) except OSError: discard
  # Second attempt also collided — lost a race to another live 3code.
  raise lockHeldError(path, lockPath, readOwnerPid(lockPath))

proc releaseSessionLock*(path: string) =
  if path == "": return
  let lockPath = sessionLockPathFor(path)
  try: removeFile(lockPath) except OSError: discard
  if activeLockPath == lockPath: activeLockPath = ""

proc releaseActiveSessionLock*() =
  if activeLockPath != "":
    try: removeFile(activeLockPath) except OSError: discard
    activeLockPath = ""

# ---------------------------------------------------------------------------
# Directory locks.
#
# Only one 3code process may hold a given working directory at a time: two
# sessions editing the same cwd would race on prompt drafts, the cwd session
# index, and the per-cwd pending draft file. The lock is keyed by the
# collision-free mangled cwd (same scheme as the cwd session index and the
# pending draft path) so distinct directories never share a lock.
#
# Same atomic-create + stale-reclaim pattern as the session lock: POSIX uses
# open(O_CREAT|O_EXCL), Windows uses CreateFileW(CREATE_NEW). On collision
# we read the holding pid; if that process is no longer alive the stale lock
# is removed and acquisition retries once. Only a genuinely-live holder raises
# DirLocked. The currently-held dir-lock path is tracked in a module global
# so an exit proc can release whatever the process most recently held.
# ---------------------------------------------------------------------------

var activeDirLockPath* = ""

proc dirLockDir*(): string =
  tempDir() / "3code" / "dirlock"

proc dirLockPathFor*(cwd: string): string =
  dirLockDir() / (mangleCwd(cwd) & ".lock")

type DirLocked* = object of CatchableError

proc lockHeldDirError*(cwd, lockPath, owner, sessionId: string): ref DirLocked =
  var mtime = getTime()
  try: mtime = getLastModificationTime(lockPath) except OSError: discard
  var holder = ""
  if owner.len > 0:
    holder = " (pid " & owner
    if sessionId.len > 0: holder &= ", session " & sessionId
    holder &= ")"
  newException(DirLocked,
    "directory \"" & cwd & "\" is already open" & holder &
    " in another running 3code process. Lock file: " & lockPath &
    " (last modified " & format(mtime.local, "yyyy-MM-dd HH:mm:ss") & ")." &
    " If no 3code is running, the lock is stale and the pid check failed —" &
    " delete it: " & lockPath)

proc tryCreateDirLockFile(lockPath: string; pid: string): int =
  ## Atomically create `lockPath` and write `pid` into it. Returns 0 on
  ## success, -1 if the file already exists (collision). Any other failure
  ## raises DirLocked.
  when defined(posix):
    let p = lockPath.cstring
    let fd = open(p, O_WRONLY or O_CREAT or O_EXCL, 0o600.cint)
    if fd < 0:
      let errno = osLastError()
      if errno.int32 == EEXIST.int32: return -1
      raise newException(DirLocked,
        "could not create directory lock " & lockPath & ": " & osErrorMsg(errno))
    writeOwnerInfo(fd, pid)
    discard close(fd)
    0
  else:
    let h = winlean.createFileW(newWideCString(lockPath),
                                WingenGenericWrite, 0'i32, nil,
                                WinCreateNew, WinFileAttributeNormal, 0)
    if h == INVALID_HANDLE_VALUE:
      let errno = osLastError()
      if errno.int32 == 80'i32 or errno.int32 == 183'i32: return -1
      raise newException(DirLocked,
        "could not create directory lock " & lockPath & ": " & osErrorMsg(errno))
    writeOwnerInfo(h, pid)
    discard winlean.closeHandle(h)
    0

proc acquireDirLock*(cwd: string; sessionPath = "") =
  ## Atomically claim the directory lock for `cwd`. If a lock exists but its
  ## owner process is no longer alive, it's treated as stale and removed
  ## automatically, then acquisition retries once. Raises DirLocked only when
  ## another live 3code process genuinely holds the lock. `sessionPath`, when
  ## known, is recorded as a second line so the collision error can name the
  ## holder's session instead of a bare pid.
  if cwd == "": return
  let dir = dirLockDir()
  try: createDir(dir) except OSError: discard
  let lockPath = dirLockPathFor(cwd)
  let pid = $getCurrentProcessId()
  let sid = sessionIdFromPath(sessionPath)
  let ownerData = if sid.len > 0: pid & "\n" & sid else: pid
  for attempt in 0 .. 1:
    if tryCreateDirLockFile(lockPath, ownerData) >= 0:
      activeDirLockPath = lockPath
      return
    let owner = readOwnerPid(lockPath)
    var ownerPid = -1
    try: ownerPid = parseInt(owner) except ValueError: discard
    if ownerPid > 0 and pidAlive(ownerPid):
      raise lockHeldDirError(cwd, lockPath, owner, readOwnerSessionId(lockPath))
    try: removeFile(lockPath) except OSError: discard
  raise lockHeldDirError(cwd, lockPath, readOwnerPid(lockPath),
                         readOwnerSessionId(lockPath))

proc releaseDirLock*(cwd: string) =
  if cwd == "": return
  let lockPath = dirLockPathFor(cwd)
  try: removeFile(lockPath) except OSError: discard
  if activeDirLockPath == lockPath: activeDirLockPath = ""

proc releaseActiveDirLock*() =
  if activeDirLockPath != "":
    try: removeFile(activeDirLockPath) except OSError: discard
    activeDirLockPath = ""

proc updateActiveDirLockSession*(sessionPath: string) =
  ## Rewrite the session-id line of the dir lock this process holds, for when
  ## the live session id moves (:clear forks a fresh one). Keeping it current
  ## means a collision report from another process never names a session this
  ## process has already abandoned. Best-effort: a failed rewrite only means
  ## the report falls back to the previous id.
  if activeDirLockPath == "": return
  let sid = sessionIdFromPath(sessionPath)
  try:
    writeFile(activeDirLockPath,
              $getCurrentProcessId() & (if sid.len > 0: "\n" & sid else: ""))
  except CatchableError: discard

proc listSessionPaths*(): seq[string] =
  let d = sessionDir()
  if not dirExists(d): return
  for kind, path in walkDir(d):
    if kind == pcFile and path.endsWith(SessionExt):
      result.add path
  result.sort(order = SortOrder.Descending)

# ---------- record parser ----------

type
  Record = object
    role: string
    args: seq[string]
    body: string

const BodyEnd = "~~"
  ## Column-0 terminator closing a record body that ends in a newline.
  ## Body lines are always two-space indented (or blank), so this never
  ## collides with content. Without it a trailing blank line and a trailing
  ## single newline are indistinguishable, and tool results (whose wire
  ## content ends in `\n`) lose their last byte on every save/load
  ## round-trip. A body not ending in a newline needs no terminator; the
  ## next header closes it as before.

proc trimTrailingEmptyLegacy(s: var seq[string]) =
  ## Old-codec behavior for records without a terminator: every trailing
  ## blank line was a record separator, never content.
  while s.len > 0 and s[^1].len == 0:
    s.setLen s.len - 1

proc isHeaderLine(line: string): bool =
  if line.len == 0: return false
  if line[0] == ' ' or line[0] == '\t': return false
  for r in Roles:
    if line == r or line.startsWith(r & " "):
      return true
  false

proc parseRecords(text: string): seq[Record] =
  var current = Record()
  var inRecord = false
  var bodyLines: seq[string]
  var closed = false
  proc flush(buf: var seq[Record]) =
    if not inRecord: return
    # A terminator says the body ended in a newline; everything indented
    # above it is content, blanks included. Without one (legacy shape, or
    # a body not ending in a newline) trailing blank lines were record
    # separators, so they are dropped exactly like the old codec did.
    if closed:
      current.body = bodyLines.join("\n") & "\n"
    else:
      trimTrailingEmptyLegacy(bodyLines)
      current.body = bodyLines.join("\n")
    buf.add current
    current = Record()
    bodyLines.setLen 0
    inRecord = false
    closed = false
  for line in text.splitLines:
    if inRecord and line == BodyEnd:
      closed = true
      flush(result)
      continue
    if isHeaderLine(line):
      flush(result)
      let parts = line.split(' ')
      current.role = parts[0]
      if parts.len > 1:
        for p in parts[1 .. ^1]:
          if p.len > 0: current.args.add p
      inRecord = true
    elif inRecord:
      if line.len >= 2 and line[0] == ' ' and line[1] == ' ':
        bodyLines.add line[2 .. ^1]
      elif line.len == 0:
        bodyLines.add ""
      else:
        bodyLines.add line  # tolerate misindented body
  flush(result)

proc parseArgs(args: seq[string]): tuple[
    pos: seq[string],
    kv: Table[string, string],
    flags: Table[string, string]] =
  result.kv = initTable[string, string]()
  result.flags = initTable[string, string]()
  for a in args:
    if a.len == 0: continue
    if a[0] == '+':
      let body = a[1 .. ^1]
      let eq = body.find('=')
      if eq < 0: result.flags[body] = ""
      else: result.flags[body[0 ..< eq]] = body[eq + 1 .. ^1]
    elif '=' in a:
      let eq = a.find('=')
      result.kv[a[0 ..< eq]] = a[eq + 1 .. ^1]
    else:
      result.pos.add a

proc parseSections(body: string): seq[(string, string)] =
  ## Split `body` on `-- name --` separator lines. The first section is
  ## unlabeled (label=""). Section markers must occupy the entire line,
  ## with no leading whitespace, so prose that mentions "-- foo --" mid-line
  ## doesn't accidentally split a section.
  var label = ""
  var current: seq[string]
  for line in body.splitLines:
    if line.startsWith("-- ") and line.endsWith(" --") and line.len >= 7:
      let inner = line[3 .. ^4].strip
      result.add (label, current.join("\n"))
      label = inner
      current.setLen 0
    else:
      current.add line
  result.add (label, current.join("\n"))

# ---------- record → wire JSON ----------

proc sectionText(sections: seq[(string, string)], label: string): string =
  for s in sections:
    if s[0] == label: return s[1]
  ""

proc recordToToolCall(r: Record): JsonNode =
  ## Reconstruct the OpenAI-shape tool_call JSON the model originally
  ## emitted. Prefers the verbatim `-- wire --` section (the exact bytes
  ## the server sent, so a resumed request replays the cache-eligible
  ## history byte-for-byte); falls back to rebuilding from the readable
  ## sections for pre-wire logs. The legacy rebuild loses extra fields
  ## the model included beyond what each dispatcher reads, which the
  ## model would have ignored on the next turn anyway.
  let (pos, _, _) = parseArgs(r.args)
  let id = if pos.len >= 1: pos[0] else: ""
  let tool = if pos.len >= 2: pos[1] else: ""
  let path = if pos.len >= 3: pos[2] else: ""
  let sections = parseSections(r.body)
  block wireSection:
    let verbatim = sectionText(sections, "wire")
    if verbatim.len == 0: break wireSection
    try:
      let j = parseJson(verbatim)
      if j.kind == JObject:
        return j
    except CatchableError:
      discard  # corrupt wire section: fall through to the rebuild
  let args =
    case tool
    of "bash":
      var a = newJObject()
      a["command"] = %sectionText(sections, "")
      let stdin = sectionText(sections, "stdin")
      if stdin.len > 0: a["stdin"] = %stdin
      a
    of "shell":
      let line = sectionText(sections, "")
      let stdin = sectionText(sections, "stdin")
      var cmdArr = newJArray()
      cmdArr.add %"bash"
      cmdArr.add %"-lc"
      cmdArr.add %line
      var a = newJObject()
      a["cmd"] = cmdArr
      if stdin.len > 0: a["stdin"] = %stdin
      a
    of "write":
      %*{"path": path, "body": sectionText(sections, "")}
    of "patch":
      var arr = newJArray()
      var search = ""
      for s in sections:
        case s[0]
        of "search": search = s[1]
        of "replace":
          arr.add %*{"search": search, "replace": s[1]}
          search = ""
        else: discard
      %*{"path": path, "edits": arr}
    of "apply_patch":
      %*{"input": sectionText(sections, "")}
    of "clear":
      %*{"prompt": sectionText(sections, "")}
    of "dmail":
      %*{"checkpoint": (try: parseInt(path) except ValueError: -1),
         "message": sectionText(sections, "")}
    of "read":
      var a = %{"path": %path}
      let hdr = if pos.len > 3: pos[3 ..^ 1].join(" ") else: ""
      let nums = if "-" in hdr: hdr.split('-') else: @[]
      if nums.len == 2:
        try:
          let off = parseInt(nums[0])
          let last = parseInt(nums[1])
          if off > 0:
            a["offset"] = %off
            a["limit"] = %(if last >= off: last - off + 1 else: 0)
        except ValueError: discard
      a
    of "web_search":
      %*{"query": sectionText(sections, "")}
    of "web_fetch":
      %*{"url": sectionText(sections, "")}
    of "update_plan", "todo":
      var items = newJArray()
      for s in sections:
        if s[0] == "item":
          var lines = s[1].splitLines
          let status = if lines.len > 0: lines[0].strip else: "pending"
          let text = if lines.len > 1: lines[1 .. ^1].join("\n").strip else: ""
          if text.len > 0:
            items.add %*{"text": text, "status": status}
      %*{"items": items}
    else:
      newJObject()
  %*{
    "id": id,
    "type": "function",
    "function": {"name": tool, "arguments": $args}
  }

proc recordToUsage(r: Record): JsonNode =
  let (_, kv, _) = parseArgs(r.args)
  proc num(k: string): int =
    try: parseInt(kv.getOrDefault(k, "0")) except ValueError: 0
  let fresh = num("fresh")
  let cached = num("cached")
  let prompt = fresh + cached
  var elapsed = 0
  if "elapsed" in kv:
    let e = kv["elapsed"]
    let trimmed = if e.endsWith("s"): e[0 ..< e.len - 1] else: e
    try: elapsed = parseInt(trimmed) except ValueError: discard
  result = %*{
    "promptTokens": prompt,
    "completionTokens": num("out"),
    "totalTokens": prompt + num("out"),
    "cachedTokens": cached,
    "elapsed": elapsed,
  }
  # Preserve timestamp positionally (first non-key arg).
  let (pos, _, _) = parseArgs(r.args)
  if pos.len > 0: result["ts"] = %pos[0]

# ---------- writer ----------

const
  CtxOpen = "<session_context>"
  CtxClose = "</session_context>"
  NotesOpen = "<project_notes>"
  NotesClose = "</project_notes>"

proc splitPreamble(content: string): tuple[ctx, notes, body: string] =
  ## Peel the preamble off a user message's content byte-exactly. Only the
  ## exact grammar `sessionPreamble` emits is peeled: `<session_context>\n`
  ## at position 0, a closing tag on its own line, the optional
  ## `\n\n<project_notes>\n...\n</project_notes>` block, and a `\n\n`
  ## before the user's own text. Anything else (user-typed tags, odd
  ## spacing) is not a 3code preamble and stays in `body` so the wire
  ## bytes round-trip untouched.
  if not content.startsWith(CtxOpen & "\n"): return ("", "", content)
  let j = content.find("\n" & CtxClose)
  if j < 0: return ("", "", content)
  result.ctx = content[CtxOpen.len + 1 ..< j]
  var rest = content[j + CtxClose.len + 1 .. ^1]
  if rest.startsWith("\n\n" & NotesOpen & "\n"):
    let k = rest.find("\n" & NotesClose)
    if k >= 0:
      result.notes = rest[NotesOpen.len + 3 ..< k]
      rest = rest[k + NotesClose.len + 1 .. ^1]
  if rest.startsWith("\n\n"):
    result.body = rest[2 .. ^1]
  elif result.notes.len == 0:
    # Not the exact grammar: keep the whole content as body so nothing
    # is silently rewritten.
    return ("", "", content)
  else:
    result.body = rest

proc joinPreamble(ctx, notes, body: string): string =
  ## Exact inverse of `splitPreamble`, reproducing `sessionPreamble`'s
  ## grammar: no `strip`, no reflow.
  if ctx.len == 0: return body
  result = CtxOpen & "\n" & ctx & "\n" & CtxClose
  if notes.len > 0:
    result.add "\n\n" & NotesOpen & "\n" & notes & "\n" & NotesClose
  # `sessionPreamble` always joins with "\n\n", even under an empty user
  # body, so an empty submission keeps its trailing separator byte-exactly.
  result.add "\n\n" & body

proc emitRecord(s: var string, header, body: string) =
  ## Write a record byte-exactly: body lines two-space indented, a
  ## `BodyEnd` terminator only when the body ends in a newline (the
  ## ambiguous case), and a blank separator line after every record.
  ## Round-trip invariant: parseRecords of this record yields `body` back.
  s.add header
  s.add '\n'
  if body.len > 0:
    var b = body
    let terminated = b.endsWith("\n")
    if terminated: b.setLen b.len - 1
    for l in b.split('\n'):
      s.add "  "
      s.add l
      s.add '\n'
    if terminated: s.add BodyEnd & "\n"
  s.add '\n'

proc emitHeaderOnly(s: var string, header: string) =
  s.add header
  s.add "\n\n"

proc humanBody(name: string, args: JsonNode): string =
  ## Readable rendering of a tool call for the audit trail / `--list`. The
  ## loader never reads this back for wire parity; `recordToToolCall`
  ## prefers the `-- wire --` section. `nil` args or an unrecognized name
  ## yield "" so the record degenerates to just the wire section.
  if args == nil or args.kind != JObject: return ""
  case name
  of "bash":
    result = args{"command"}.getStr("")
    let stdin = args{"stdin"}.getStr("")
    if stdin.len > 0:
      if not result.endsWith("\n"): result.add "\n"
      result.add "-- stdin --\n" & stdin
  of "shell":
    let argv = args{"cmd"}.getElems
    result = if argv.len > 0: argv[^1].getStr else: ""
    let stdin = args{"stdin"}.getStr("")
    if stdin.len > 0:
      if not result.endsWith("\n"): result.add "\n"
      result.add "-- stdin --\n" & stdin
  of "write":
    result = args{"body"}.getStr("")
  of "patch":
    let edits = args{"edits"}
    if edits != nil and edits.kind == JArray:
      for e in edits:
        if result.len > 0 and not result.endsWith("\n"): result.add "\n"
        result.add "-- search --\n"
        result.add e{"search"}.getStr("")
        if not result.endsWith("\n"): result.add "\n"
        result.add "-- replace --\n"
        result.add e{"replace"}.getStr("")
  of "apply_patch":
    result = args{"input"}.getStr("")
  of "clear":
    result = args{"prompt"}.getStr("")
  of "dmail":
    result = args{"message"}.getStr("")
  of "web_search":
    result = args{"query"}.getStr("")
  of "web_fetch":
    result = args{"url"}.getStr("")
  of "update_plan", "todo":
    let items =
      if args{"items"} != nil and args{"items"}.kind == JArray: args{"items"}
      else: args{"steps"}
    for item in items.getElems:
      if result.len > 0 and not result.endsWith("\n"): result.add "\n"
      result.add "-- item --\n"
      result.add item{"status"}.getStr("pending") & "\n"
      result.add item{"text"}.getStr(item{"description"}.getStr(""))
  else: discard

proc emitToolUse(s: var string, tc: JsonNode) =
  ## Human-readable body (what diff review and `--list` show) plus a
  ## trailing `-- wire --` section with the exact tool_call JSON the
  ## server sent: key order, extra fields (`index`, ...), raw argument
  ## bytes. `recordToToolCall` prefers the wire section on load, so a
  ## resumed session re-sends byte-identical history and the provider's
  ## prompt cache stays hot.
  let id = tc{"id"}.getStr("")
  let fn = tc{"function"}
  let rawName = if fn != nil: fn{"name"}.getStr("") else: ""
  let argsStr = if fn != nil: fn{"arguments"}.getStr("") else: ""
  let args = try: parseJson(if argsStr == "": "{}" else: argsStr)
             except CatchableError as e:
               debugOut "tool_call " & rawName & " has malformed args: " & e.msg
               newJObject()
  var name = rawName
  let pipe = name.find("<|")
  if pipe >= 0: name = name[0 ..< pipe]
  var body = humanBody(name, args)
  if body.len > 0 and not body.endsWith("\n"): body.add "\n"
  body.add "-- wire --\n" & $tc
  # Headers stay lossy-parseable for the legacy rebuild in recordToToolCall:
  # `read` carries its offset range and `dmail` its checkpoint number.
  let hdr = case name
    of "write", "patch":
      let path = args{"path"}.getStr("")
      "tool_use " & id & " " & name & (if path.len > 0: " " & path else: "")
    of "read":
      let path = args{"path"}.getStr("")
      let offset = args{"offset"}.getInt(0)
      let limit = args{"limit"}.getInt(0)
      var h = "tool_use " & id & " read " & path
      if offset > 0 or limit > 0:
        h.add " " & $offset & "-" &
          (if limit > 0: $(offset + limit - 1) else: "end")
      h
    of "dmail":
      "tool_use " & id & " dmail " & $args{"checkpoint"}.getInt(-1)
    else:
      "tool_use " & id & " " & name
  emitRecord s, hdr, body

proc emitTokens(s: var string, usage: JsonNode) =
  if usage == nil or usage.kind != JObject: return
  let total = usage{"totalTokens"}.getInt(0)
  if total <= 0: return
  let prompt = usage{"promptTokens"}.getInt(0)
  let cached = usage{"cachedTokens"}.getInt(0)
  let fresh = max(0, prompt - cached)
  let outTok = usage{"completionTokens"}.getInt(0)
  let elapsed = usage{"elapsed"}.getInt(0)
  let ts = usage{"ts"}.getStr("")
  let hit = if prompt > 0: int((cached.float * 100.0) / prompt.float + 0.5)
            else: 0
  var hdr = "tokens"
  if ts.len > 0: hdr.add " " & ts
  hdr.add " fresh=" & $fresh
  hdr.add " cached=" & $cached
  hdr.add " out=" & $outTok
  hdr.add " hit=" & $hit & "%"
  hdr.add " elapsed=" & $elapsed & "s"
  emitHeaderOnly s, hdr

proc renderSession*(session: Session, messages: JsonNode): string =
  var s = ""
  var hdr = "session"
  if session.created.len > 0: hdr.add " " & session.created
  if session.profileName.len > 0: hdr.add " profile=" & session.profileName
  if session.cwd.len > 0: hdr.add " cwd=" & session.cwd
  # Cache-parity stamp: which profile built the conversation's system
  # prompt. The loader restores it into PromptState so a resume rebuilds
  # from the same profile (and builds fresh when it no longer matches).
  if session.promptState.identity.len > 0:
    hdr.add " prompt_identity=" & session.promptState.identity
  emitHeaderOnly s, hdr
  # The dynamic input the system prompt substituted: persisted so the
  # resume-time rebuild re-sends the exact catalog bytes the live session
  # sent. The prompt template itself is constructed from the profile.
  if session.promptState.skills.len > 0:
    emitRecord s, "skills", session.promptState.skills
  if messages == nil or messages.kind != JArray: return s
  # Map tool_call_id → exit code via the parallel toolLog (entries are
  # appended in the same order tool_calls fire across the message stream).
  var idToExit = initTable[string, int]()
  block:
    var idx = 0
    for m in messages:
      if m.kind != JObject: continue
      if m{"role"}.getStr != "assistant": continue
      let tcs = m{"tool_calls"}
      if tcs == nil or tcs.kind != JArray: continue
      for tc in tcs:
        let id = tc{"id"}.getStr
        if idx < session.toolLog.len:
          idToExit[id] = session.toolLog[idx].code
        inc idx
  for m in messages:
    if m.kind != JObject: continue
    case m{"role"}.getStr
    of "system":
      # Constructed from the profile at resume; never persisted (see the
      # module doc). Nothing to write for the wire shape either - the
      # loader backfills a system message at index 0.
      discard
    of "user":
      let raw = m{"content"}.getStr("")
      let (ctx, notes, body) = splitPreamble(raw)
      if ctx.len > 0: emitRecord s, "context", ctx
      if notes.len > 0: emitRecord s, "project_notes", notes
      emitRecord s, "user", body
    of "assistant":
      # Always emit the reasoning record, empty included: the live
      # transports stamp `reasoning_content` on every assistant message,
      # and a resumed assistant without the key would diverge from the
      # bytes the live session sent.
      emitRecord s, "reasoning", m{"reasoning_content"}.getStr("")
      let content = m{"content"}.getStr("")
      let tcs = m{"tool_calls"}
      let hasToolCalls = tcs != nil and tcs.kind == JArray and tcs.len > 0
      if content.len == 0 and not hasToolCalls:
        # Persist the empty turn with the canonical marker (`EmptyReplyMsg`)
        # so the wire format keeps the exchange paired. Replay maps the
        # marker back to the grey fallback rendering, never to prose. The
        # provider's explanation rides along on the header so a resumed
        # replay can render the same "empty reply: length ..." line the
        # live path painted.
        var hdr = "assistant"
        let fr = m{"finish_reason"}.getStr("")
        if fr.len > 0: hdr.add " finish=" & fr
        emitRecord s, hdr, EmptyReplyMsg
      else:
        emitRecord s, "assistant", content
      if hasToolCalls:
        for tc in tcs:
          emitToolUse s, tc
      emitTokens s, m{"usage"}
    of "tool":
      let id = m{"tool_call_id"}.getStr
      let exitCode = idToExit.getOrDefault(id, 0)
      emitRecord s, "tool_result " & id & " exit=" & $exitCode,
                 m{"content"}.getStr("")
    else: discard
  s

# ---------- save / load ----------

proc isInSessionDir(path: string): bool =
  ## True when `path` lives under the managed sessions directory, i.e. when
  ## it should be (and can be) indexed for cwd lookup. A `-s /custom.3log`
  ## save target lives elsewhere and is deliberately left unindexed.
  let dir = sessionDir()
  if not path.startsWith(dir): return false
  # dir has no trailing separator; require the next char to be one so that
  # (say) `sessions-backup/x.3log` doesn't match.
  path.len > dir.len and (path[dir.len] == '/' or path[dir.len] == '\\')

proc saveSession*(session: Session, messages: JsonNode) =
  if session.savePath == "": return
  let firstSave = not hasSavedSession(session.savePath)
  try:
    createDir(session.savePath.parentDir)
    writeFile(session.savePath, renderSession(session, messages))
    when defined(posix):
      # chmod 0600 — the transcript holds anything pasted into a prompt.
      discard posix.chmod(session.savePath.cstring, 0o600)
  except CatchableError as e:
    stderr.writeLine "3code: session save failed: " & e.msg
  # Index a brand-new session under its cwd so resume-latest finds it
  # without parsing. Skipped on re-saves (existing file → no duplicate line)
  # and for out-of-tree `-s` targets. cwd is always set in normal use
  # (`session.cwd = safeCwd()`), and an empty cwd is silently dropped.
  if firstSave and session.cwd != "" and isInSessionDir(session.savePath):
    appendSessionIndex(session.cwd, sessionIdFromPath(session.savePath))

proc writeDraftAtomic(path, text: string) =
  ## Create parent dirs and atomically write `text` to `path` (temp + rename),
  ## so a crash mid-write can never leave a truncated `.prompt` visible.
  createDir(path.parentDir)
  let tmp = path & ".tmp"
  writeFile(tmp, text)
  moveFile(tmp, path)

proc removeIfExists(path: string) =
  if fileExists(path):
    try: removeFile(path) except OSError: discard

proc saveDraft*(session: Session, text: string) =
  ## Persist the current prompt-editor text as an atomic draft sidecar so an
  ## unexpected shutdown never loses a half-typed prompt. Writes to whichever
  ## scope `currentDraftPath` picks (cwd-keyed pending before the first turn,
  ## session-id-keyed after). A blank draft removes the sidecar rather than
  ## leaving an empty file, so an idle editor produces no draft. No-op without
  ## a cwd to key on (and no savePath).
  if session.savePath == "" and session.cwd == "": return
  let path = currentDraftPath(session)
  if text.len == 0:
    removeIfExists(path)
    return
  try:
    writeDraftAtomic(path, text)
  except CatchableError as e:
    stderr.writeLine "3code: draft save failed: " & e.msg

proc clearDraft*(session: Session) =
  ## Remove the prompt draft sidecar(s). Called when a prompt is committed so a
  ## clean exit doesn't leave a stale draft. Removes both scopes — whichever was
  ## active at submit time — so this is correct regardless of pre/post-first-turn
  ## state. Cheap and a no-op when neither exists.
  if session.savePath != "":
    removeIfExists(draftPathFor(session.savePath))
  if session.cwd != "":
    removeIfExists(pendingDraftPathFor(session.cwd))

proc loadDraft*(sessionPath: string): string =
  ## Read the session-id-keyed prompt draft for `sessionPath`, or "" if there
  ## is none or it is unreadable. Used by resume (post-first-turn drafts). The
  ## empty string is indistinguishable from absence, which is fine: an empty
  ## draft restores to an empty editor.
  if sessionPath == "": return ""
  let path = draftPathFor(sessionPath)
  if not fileExists(path): return ""
  try: readFile(path) except CatchableError: ""

proc loadPendingDraft*(cwd: string): string =
  ## Read the cwd-keyed pending prompt draft for `cwd`, or "" if there is none
  ## or it is unreadable. Used to restore an unsent prompt from a previous,
  ## killed-before-first-turn run when starting a fresh session in the same
  ## directory.
  if cwd == "": return ""
  let path = pendingDraftPathFor(cwd)
  if not fileExists(path): return ""
  try: readFile(path) except CatchableError: ""

proc clearPendingDraft*(cwd: string) =
  ## Remove the cwd-keyed pending prompt draft for `cwd`. No-op when none
  ## exists.
  if cwd == "": return
  removeIfExists(pendingDraftPathFor(cwd))

proc buildToolLogFromMessages(messages: JsonNode,
                              exitByCallId: Table[string, int]): seq[ToolRecord] =
  var idToContent = initTable[string, string]()
  for m in messages:
    if m.kind != JObject: continue
    if m{"role"}.getStr != "tool": continue
    idToContent[m{"tool_call_id"}.getStr] = m{"content"}.getStr("")
  for m in messages:
    if m.kind != JObject: continue
    if m{"role"}.getStr != "assistant": continue
    let tcs = m{"tool_calls"}
    if tcs == nil or tcs.kind != JArray: continue
    for tc in tcs:
      let id = tc{"id"}.getStr
      let fn = tc{"function"}
      let rawName = if fn != nil: fn{"name"}.getStr else: ""
      let argsStr = if fn != nil: fn{"arguments"}.getStr("") else: ""
      let args = try: parseJson(if argsStr == "": "{}" else: argsStr)
                 except CatchableError as e:
                   debugOut "tool_call " & rawName & " has malformed args: " & e.msg
                   newJObject()
      var name = rawName
      let pipe = name.find("<|")
      if pipe >= 0: name = name[0 ..< pipe]
      let act =
        case name
        of "bash":
          Action(kind: akBash,
                 body: args{"command"}.getStr,
                 stdin: args{"stdin"}.getStr)
        of "shell":
          let argv = args{"cmd"}.getElems
          let line = if argv.len > 0: argv[^1].getStr else: ""
          Action(kind: akBash, body: line, stdin: args{"stdin"}.getStr)
        of "write":
          Action(kind: akWrite,
                 path: args{"path"}.getStr,
                 body: args{"body"}.getStr)
        of "patch":
          var a = Action(kind: akPatch, path: args{"path"}.getStr)
          let edits = args{"edits"}
          if edits != nil and edits.kind == JArray:
            for e in edits:
              a.edits.add (e{"search"}.getStr, e{"replace"}.getStr)
          a
        of "apply_patch":
          Action(kind: akApplyPatch, body: args{"input"}.getStr)
        of "read":
          Action(kind: akRead,
                 path: args{"path"}.getStr,
                 offset: args{"offset"}.getInt,
                 limit: args{"limit"}.getInt)
        of "update_plan", "todo":
          var a = Action(kind: akPlan)
          let items =
            if args{"items"} != nil and args{"items"}.kind == JArray: args{"items"}
            else: args{"steps"}
          for item in items.getElems:
            let text = item{"text"}.getStr(item{"description"}.getStr)
            if text.len > 0:
              a.plan.add PlanItem(text: text, status: item{"status"}.getStr)
          a
        of "web_search":
          Action(kind: akWebSearch, body: args{"query"}.getStr)
        of "web_fetch":
          Action(kind: akWebFetch, body: args{"url"}.getStr)
        of "clear":
          Action(kind: akClear, body: args{"prompt"}.getStr)
        of "dmail":
          Action(kind: akDMail, path: $args{"checkpoint"}.getInt(-1),
                body: args{"message"}.getStr)
        of "edit":
          var a = Action(kind: akPatch, path: args{"path"}.getStr)
          let edits = args{"edits"}
          if edits != nil and edits.kind == JArray:
            for e in edits:
              a.edits.add (e{"search"}.getStr, e{"replace"}.getStr)
          a
        of "applypatch", "apply-patch":
          Action(kind: akApplyPatch, body: args{"input"}.getStr)
        else:
          Action(kind: akError, path: name)
      result.add ToolRecord(
        banner: bannerFor(act),
        output: idToContent.getOrDefault(id, ""),
        code: exitByCallId.getOrDefault(id, 0),
        kind: act.kind,
        plan: act.plan,
      )

proc buildPlanFromMessages(messages: JsonNode,
                           exitByCallId: Table[string, int]): seq[PlanItem] =
  for m in messages:
    if m.kind != JObject: continue
    if m{"role"}.getStr != "assistant": continue
    let tcs = m{"tool_calls"}
    if tcs == nil or tcs.kind != JArray: continue
    for tc in tcs:
      let id = tc{"id"}.getStr
      if exitByCallId.getOrDefault(id, 0) != 0: continue
      let fn = tc{"function"}
      let rawName = if fn != nil: fn{"name"}.getStr else: ""
      var name = rawName
      let pipe = name.find("<|")
      if pipe >= 0: name = name[0 ..< pipe]
      if name != "update_plan" and name != "todo": continue
      let argsStr = if fn != nil: fn{"arguments"}.getStr("") else: ""
      let args = try: parseJson(if argsStr == "": "{}" else: argsStr)
                 except CatchableError as e:
                   debugOut "tool_call " & rawName & " has malformed args: " & e.msg
                   newJObject()
      let items =
        if args{"items"} != nil and args{"items"}.kind == JArray: args{"items"}
        else: args{"steps"}
      result.setLen 0
      for item in items.getElems:
        let text = item{"text"}.getStr(item{"description"}.getStr)
        if text.len > 0:
          result.add PlanItem(text: text, status: item{"status"}.getStr)

proc loadSessionFile*(path: string): (Session, JsonNode) =
  let raw = try: readFile(path)
            except CatchableError as e:
              die("cannot read session " & path & ": " & e.msg, ExitConfig)
  let records = parseRecords(raw)
  var sess = Session(savePath: path)
  var messages = newJArray()
  var pendingReasoning = ""
  var pendingCtx = ""
  var pendingNotes = ""
  var lastAssistant: JsonNode = nil
  var exitByCallId = initTable[string, int]()
  var hasResolvedSystem = false
  for r in records:
    let (pos, kv, _) = parseArgs(r.args)
    case r.role
    of "session":
      if pos.len > 0: sess.created = pos[0]
      if "profile" in kv: sess.profileName = kv["profile"]
      if "cwd" in kv: sess.cwd = kv["cwd"]
      if "prompt_identity" in kv:
        sess.promptState.identity = kv["prompt_identity"]
    of "skills":
      # The catalog the system prompt was built with (first record wins;
      # only the resume-time rebuild consumes it, never the wire).
      if sess.promptState.skills.len == 0:
        sess.promptState.skills = r.body
      lastAssistant = nil
    of "system":
      # Legacy verbatim prompt: kept for the wire shape (index 0 must be
      # a system message) but never adopted into PromptState - resume
      # reconstructs from the profile. Duplicates (hand-merges, exotic
      # histories) drop here rather than re-sending.
      if hasResolvedSystem: discard
      else:
        messages.add %*{"role": "system", "content": r.body}
        hasResolvedSystem = true
      lastAssistant = nil
    of "context":
      pendingCtx = r.body
    of "project_notes":
      pendingNotes = r.body
    of "user":
      let content = joinPreamble(pendingCtx, pendingNotes, r.body)
      pendingCtx = ""
      pendingNotes = ""
      messages.add %*{"role": "user", "content": content}
      lastAssistant = nil
    of "reasoning":
      pendingReasoning = r.body
    of "assistant":
      # `reasoning_content` is always present (possibly empty): the live
      # transports (`buildStreamAssistantMsg`/`buildBatchAssistantMsg`)
      # set it on every assistant message, and wire parity for
      # think-back families (deepseek/glm/kimi) requires the key set to
      # survive resume unchanged.
      let msg = %*{"role": "assistant",
                   "content": r.body,
                   "reasoning_content": pendingReasoning}
      # A tool-less empty reply saved with the provider's explanation
      # (`assistant finish=length`, written by `renderSession`) restores
      # `finish_reason` so replay can render the same explanatory line the
      # live path painted instead of the bare empty-reply fallback.
      if "finish" in kv and kv["finish"].len > 0:
        msg["finish_reason"] = %kv["finish"]
      pendingReasoning = ""
      messages.add msg
      lastAssistant = msg
    of "tool_use":
      if lastAssistant == nil:
        stderr.writeLine "3code: orphan tool_use in " & path
        continue
      let tc = recordToToolCall(r)
      var tcs = lastAssistant{"tool_calls"}
      if tcs == nil:
        tcs = newJArray()
        lastAssistant["tool_calls"] = tcs
      tcs.add tc
    of "tokens":
      if lastAssistant != nil:
        let u = recordToUsage(r)
        lastAssistant["usage"] = u
        sess.usage.promptTokens += u{"promptTokens"}.getInt(0)
        sess.usage.completionTokens += u{"completionTokens"}.getInt(0)
        sess.usage.totalTokens += u{"totalTokens"}.getInt(0)
        sess.usage.cachedTokens += u{"cachedTokens"}.getInt(0)
        sess.lastPromptTokens = u{"promptTokens"}.getInt(0)
    of "tool_result":
      let id = if pos.len > 0: pos[0] else: ""
      let exitCode = try: parseInt(kv.getOrDefault("exit", "0"))
                     except ValueError: 0
      exitByCallId[id] = exitCode
      messages.add %*{"role": "tool", "tool_call_id": id, "content": r.body}
      lastAssistant = nil
    else: discard
  # Repair orphaned tool_calls / orphaned tool results. A session saved
  # mid-batch, or compacted across a parallel tool-call, can leave
  # unpaired ids that Kimi/Moonshot reject with 400 `tool_call_id is not
  # found`. Shared with the wire path in callModel.
  messages = repairToolCallPairing(messages)
  # New-format files carry no `system` record (the prompt is constructed
  # at resume), so index 0 is backfilled with the placeholder
  # `refreshSystemPrompt` resolves; legacy files keep their verbatim body
  # until that same rebuild replaces it.
  if messages.len == 0 or messages[0]{"role"}.getStr != "system":
    let backfill = newJArray()
    backfill.add %*{"role": "system", "content": DefaultSystemPrompt}
    for m in messages: backfill.add m
    messages = backfill
  sess.toolLog = buildToolLogFromMessages(messages, exitByCallId)
  sess.plan = buildPlanFromMessages(messages, exitByCallId)
  (sess, messages)

# ---------- session listing helpers ----------

type SessionPreview* = object
  cwd*: string
  profile*: string
  msgCount*: int
  firstUser*: string

proc previewSession*(path: string): SessionPreview =
  ## Fast peek for `--list` and `:sessions` — reads the file, parses just
  ## enough to show cwd / profile / count / first user line. Doesn't
  ## reconstruct the full message tree.
  let raw = try: readFile(path) except CatchableError: return
  for r in parseRecords(raw):
    let (_, kv, _) = parseArgs(r.args)
    case r.role
    of "session":
      if "profile" in kv: result.profile = kv["profile"]
      if "cwd" in kv: result.cwd = kv["cwd"]
    of "system": inc result.msgCount
    of "user":
      inc result.msgCount
      if result.firstUser.len == 0:
        result.firstUser = stripPreamble(r.body).replace("\n", " ").replace("\r", " ").strip
    of "assistant", "tool_result":
      inc result.msgCount
    else: discard

proc listSessionPathsForCwd*(cwd: string): seq[string] =
  ## Sessions saved under `cwd`, latest-first — read straight from the cwd
  ## index, so it never parses a `.3log`. A missing/stale index entry is
  ## skipped via the `fileExists` check (e.g. a session deleted on disk).
  for id in indexIdsAt(sessionPathIndexDir(), cwd):
    let p = sessionDir() / (id & SessionExt)
    if fileExists(p): result.add p

proc resolveSessionPath*(id: string, cwd = ""): string =
  ## `id` is bare (no extension) or a full path. Returns "" if not found.
  ## When `id` is empty and `cwd` is set, returns the latest session for that
  ## cwd via the cwd index (no session parsed); with `cwd` unset, the latest
  ## of any via a plain directory listing.
  if id == "":
    let candidates =
      if cwd != "": listSessionPathsForCwd(cwd)
      else: listSessionPaths()
    if candidates.len == 0: return ""
    return candidates[0]
  if fileExists(id): return id
  let candidate = sessionDir() / (id & SessionExt)
  if fileExists(candidate): return candidate
  let candidate2 = sessionDir() / id
  if fileExists(candidate2): return candidate2
  ""

# ---------- Session-derived display helpers ----------

proc usageFromJson*(j: JsonNode): Usage =
  if j == nil or j.kind != JObject: return
  Usage(
    promptTokens: j{"promptTokens"}.getInt(0),
    completionTokens: j{"completionTokens"}.getInt(0),
    totalTokens: j{"totalTokens"}.getInt(0),
    cachedTokens: j{"cachedTokens"}.getInt(0),
  )

proc firstUserMessage*(messages: JsonNode): string =
  if messages == nil or messages.kind != JArray: return ""
  for m in messages:
    if m.kind == JObject and m{"role"}.getStr == "user":
      return stripPreamble(m{"content"}.getStr(""))
  ""

proc historyFile*(): string =
  let dir = userDataRoot()
  try:
    createDir(dir)
    result = dir / "history"
  except OSError, IOError:
    result = ""
