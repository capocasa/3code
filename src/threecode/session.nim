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

import std/[algorithm, json, os, sets, strformat, strutils, tables, times,
  tempfiles, sha1]
when defined(posix):
  import std/posix
when defined(windows):
  import std/[widestrs, winlean]
import types, prompts, util, actions, images
import dirsettings

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
#                 built the conversation's system prompt). The body, when
#                 present, is the session's user-facing name (`:rename`):
#                 a body rather than a header arg because names carry
#                 spaces, which the space-separated header grammar
#                 cannot (the same reason `cwd=` breaks on spaces). The
#                 listing peek (`previewSession`) reads only this record,
#                 so a named session lists without parsing the message
#                 tree; and because the body is content, `--find` terms
#                 match it like any other text.
#   skills      - the discovered skills catalog substituted into the system
#                 prompt: the dynamic input, persisted so the resume-time
#                 rebuild reproduces the live prompt bytes. The prompt
#                 itself is constructed from the profile, never stored.
#   system      - legacy: a system prompt persisted verbatim by older
#                 3code. Parsed for wire shape; resume still reconstructs.
#   user        - user input (body = message text).
#   image       - one per image content block of a user message: names the
#                 delivered file on disk (path, sha1, format, size), never
#                 the base64. Resume re-embeds the exact bytes so the
#                 re-sent message hits the provider's prompt cache.
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
               "user", "image", "reasoning", "assistant",
               "tool_use", "tool_result", "tokens", "flail",
               "goal_check"]

# ---------- paths ----------

proc sessionDir*(): string =
  userDataRoot() / "sessions"

func pathUnderDir(path, dir: string): bool =
  ## True when `path` names something inside `dir` (not `dir` itself).
  ## `dir` has no trailing separator; the next char after the prefix must
  ## be one, so `sessions-backup/x.3log` does not count as under `sessions`.
  path.len > dir.len and path.startsWith(dir) and
    (path[dir.len] == '/' or path[dir.len] == '\\')

proc isPrivateSessionPath*(path: string): bool =
  ## True when `path` lives under the private-mode transcript directory.
  pathUnderDir(path, privateSessionDir())

proc sessionIdFromPath*(path: string): string =
  let name = path.extractFilename
  if name.endsWith(SessionExt): name[0 ..< name.len - SessionExt.len] else: name

proc sessionImageDir*(sessionPath: string): string =
  ## Per-session store for vision delivery files: `<dir of the .3log>/<id>.img/`,
  ## a sibling of the session file keyed by its id so resume can find the
  ## exact delivered bytes again (providers' prompt caches key on content
  ## bytes, so re-sends must be identical). Sibling-of-the-file keeps a
  ## private session's images in the private directory with their
  ## transcript. No session file (library use without one) lands in a temp
  ## dir instead.
  if sessionPath.len > 0:
    sessionPath.parentDir / (sessionIdFromPath(sessionPath) & ".img")
  else:
    getTempDir() / "3code-img"

proc newSessionPath*(): string =
  ## Fresh unique `.3log` path: the plain sessions directory, or the
  ## private one while private mode is on, so a private session's
  ## transcript never lands beside (or inside the sandbox reach of) the
  ## ordinary ones.
  let dir = if privateMode: privateSessionDir() else: sessionDir()
  let stamp = now().format("yyyyMMdd'T'HHmmss")
  createDir(dir)
  var n = 0
  while true:
    let id = if n == 0: stamp else: stamp & "-" & $n
    let path = dir / (id & SessionExt)
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
  # The mangled name is a filename (index, drafts, dir lock): past a few
  # hundred chars it blows NAME_MAX (255) and every lock/draft write
  # fails with ENAMETOOLONG. Keep a readable head, disambiguate with a
  # digest of the full name so distinct paths never collide.
  if s.len > util.MangledNameCap:
    s = s[0 ..< util.MangledNameCap - 17] & "-" & fnv1aHex(s)
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
  ## Legacy slot from before the `.3code` store: kept for the fallback
  ## read and for tests. New writes land in the store's `config`.
  dirsettings.legacyDirCurrentPath(cwd)

proc loadDirCurrent*(cwd: string): string =
  ## The sticky `provider.model` for this directory: the nearest store
  ## (this dir or any ancestor) whose `config` sets `current`, else the
  ## legacy per-dir file, else "".
  dirsettings.dirCurrentFor(cwd)

proc saveDirCurrent*(cwd, current: string) =
  ## Atomically record `current` for this directory in its OWN store
  ## (temp + rename, same scheme as drafts), preserving the store
  ## config's other lines. Falls back to the legacy slot when the store
  ## directory cannot be created.
  dirsettings.saveDirCurrentStore(cwd, current)

proc sessionPathIndexDir*(): string =
  userDataRoot() / "session-paths"

func indexPathAt*(indexDir, cwd: string): string =
  indexDir / mangleCwd(cwd)

proc appendIndexAt*(indexDir, cwd, id: string): bool {.discardable.} =
  ## Append `id` to the cwd's index file. Returns false on failure: a missing
  ## index entry only means the session won't show in resume-latest, never a
  ## crash — the caller decides whether that is worth reporting.
  if indexDir == "" or id == "": return true
  let path = indexPathAt(indexDir, cwd)
  try:
    createDir(path.parentDir)
    let f = open(path, fmAppend)
    f.writeLine(id)
    defer: f.close()
  except CatchableError: return false
  true

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

proc appendSessionIndex*(cwd, id: string): bool {.discardable.} =
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

proc isQuitLine*(line: string): bool =
  ## Lines that end the REPL instead of reaching the model: the bare words
  ## `exit`/`quit`, or `q`/`quit`/`exit` behind any configured command
  ## prefix (`/quit` quits once `/` is enabled; under the default it is
  ## ordinary input, like every other slash-prefixed line). Shared with the
  ## REPL's submit check so a draft can never hold text that quits on submit.
  let t = line.strip
  if t in ["exit", "quit"]: return true
  if not startsWithCommandPrefix(t): return false
  colonForm(t) in [":q", ":quit", ":exit"]

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
# A live 3code process owns its session: resuming one that's already open
# in another process would interleave two writers and corrupt the
# transcript. Same for a working directory: two sessions in one cwd would
# race on prompt drafts, the cwd session index, and the pending draft.
#
# Ownership is an OS-enforced exclusive lock held open for as long as the
# process owns the resource. The pid/session text in the lock file is
# diagnostic metadata, published only after ownership is taken; it never
# decides who owns the lock.
#
# POSIX: the persistent lock file is opened O_RDWR (owner-only, no
# following symlinks) and flocked LOCK_EX|LOCK_NB on a descriptor the
# process retains until release. The descriptor is close-on-exec, so tool
# children and the update worker can never inherit ownership. The kernel
# drops the flock when the owner dies, so a crash leaves an unlocked file
# the next process claims by locking it and republishing its own owner
# record - no unlink step, hence no read/unlink/recreate race and no
# publication window: an empty or stale-text file under a held flock is
# just as held as a fully published one. The file is never unlinked.
# Unlinking a held (or just-released) path would let a second process
# lock a fresh inode while the first still owns the old one, so files
# persist after release with their owner text erased. Tests and docs
# that assumed file disappearance were updated accordingly.
#
# Windows: the retained handle carries the exclusivity. The owner opens
# GENERIC_READ|GENERIC_WRITE with FILE_SHARE_READ, so every other
# exclusive open fails with a sharing violation for as long as the handle
# is open - including reopens from the same process - while plain readers
# can still open the file for diagnostics.
#
# Upgrade compatibility: older releases enforce ownership with
# O_EXCL-create + pid liveness and honor no OS lock. A new binary
# therefore refuses to take an unlocked file whose pid text names a live
# process (conservatively a legacy holder, or a pid-reuse coincidence),
# while never deriving ownership from pid text. A legacy binary looking
# at a new binary's lock still reads the live pid line and refuses, and
# one looking at a released (emptied) file reclaims it safely. Advisory
# locking alone cannot make old and new releases fully mutually
# exclusive: a legacy binary that ignores live-pid text can steal a held
# lock. Mixed-version concurrent use of the same session or directory
# remains unsupported.
# ---------------------------------------------------------------------------

when defined(posix):
  proc c_flock(fd: cint; operation: cint): cint {.importc: "flock",
    header: "<sys/file.h>", sideEffect.}
  var LOCK_EX {.importc: "LOCK_EX", header: "<sys/file.h>".}: cint
  var LOCK_NB {.importc: "LOCK_NB", header: "<sys/file.h>".}: cint
  when defined(linux) or defined(macosx) or defined(android) or
      defined(freebsd) or defined(netbsd) or defined(openbsd) or
      defined(solaris):
    var O_NOFOLLOW {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint

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

type SessionAmbiguous* = object of CatchableError
  ## `resolveSessionPath` raises this when a prefix or name lookup matches
  ## more than one session; `msg` names the lookup and lists the matching
  ## session ids so the caller can disambiguate.

# Windows constants for the ownership-grade lock open. GENERIC_READ and
# GENERIC_WRITE together, shared only for reading: any other process's
# (or this process's) exclusive open fails with ERROR_SHARING_VIOLATION
# while the handle is retained, and read-only opens succeed for
# diagnostics.
when defined(windows):
  const
    WinFileAttributeNormal = 0x00000080'i32
    WinGenericReadWrite = 0xC0000000'i32
    WinShareRead = 1'i32
    WinShareReadWrite = 3'i32
    WinOpenAlways = 4'i32
    WinOpenExisting = 3'i32
    WinFileBegin = 0'i32
    WinSharingViolation = 32'i32

type
  LockOwnership = object
    ## One held lock: the persistent file's path plus the retained
    ## descriptor/handle whose OS lock IS the ownership. Kept from
    ## acquire until release; several can be held at once.
    path: string
    when defined(windows):
      handle: winlean.Handle
    else:
      fd: cint

  TryAcquireOutcome = enum
    taOwned      # OS lock taken; `owned` carries the live record
    taHeld       # another process holds the OS lock
    taLegacyHeld # unlocked, but the pid text names a live process

  LockAttempt = object
    kind: TryAcquireOutcome
    owned: LockOwnership
    ownerPid: string      # holder diagnostics, best effort
    ownerSession: string

var
  # The authoritative ownership records. `activeSessionLockPath` and
  # `activeDirLockPath` report the most recent of each.
  ownedSessionLocks: seq[LockOwnership]
  ownedDirLocks: seq[LockOwnership]

proc activeSessionLockPath*(): string =
  ## Path of the session lock this process owns most recently, or "".
  if ownedSessionLocks.len > 0: ownedSessionLocks[^1].path else: ""

proc activeDirLockPath*(): string =
  ## Path of the directory lock this process owns most recently, or "".
  if ownedDirLocks.len > 0: ownedDirLocks[^1].path else: ""

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

proc ownerRecord(pid, sid: string): string =
  ## The owner metadata written into a held lock file: the pid line, plus
  ## (dir locks) a second line carrying the holder's session id so a
  ## collision report can name the session, not just the process.
  if sid.len > 0: pid & "\n" & sid else: pid

proc publishOwnerInfo(own: LockOwnership; data: string) =
  ## Replace the owner record through the retained descriptor, truncating
  ## first so no stale bytes survive a shorter record. Only called while
  ## the OS lock is held.
  when defined(posix):
    discard posix.ftruncate(own.fd, 0)
    # ftruncate shrinks the file but leaves the descriptor offset where it
    # was; a write from there would zero-pad the record.
    discard posix.lseek(own.fd, 0, SEEK_SET)
    if data.len > 0:
      discard posix.write(own.fd, data.cstring, data.len)
  else:
    discard winlean.setFilePointer(own.handle, 0, nil, WinFileBegin)
    discard winlean.setEndOfFile(own.handle)
    var written: int32 = 0
    if data.len > 0:
      discard winlean.writeFile(own.handle, data.cstring, int32 data.len,
                                addr written, nil)

proc closeOwnership(own: LockOwnership) =
  ## Erase the owner record, then drop the retained descriptor/handle:
  ## the OS releases its exclusive lock and the persistent file stays
  ## behind, empty of owner text so stale metadata can never read as a
  ## live lock.
  publishOwnerInfo(own, "")
  when defined(posix):
    discard posix.close(own.fd)
  else:
    discard winlean.closeHandle(own.handle)

proc restrictLockDir(dir: string) =
  ## Owner-only lock directories in the shared temporary root: nobody
  ## else can create, replace, or read our lock files there. Best effort:
  ## a chmod another user already owns fails and changes nothing.
  when defined(posix):
    try:
      setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec})
    except OSError: discard

when defined(posix):
  proc posixOpenFlags(): cint =
    ## O_RDWR|O_CREAT plus O_NOFOLLOW where the platform has it, so a
    ## symlink planted over a lock path fails instead of being followed
    ## (and eventually truncated by our release).
    result = O_RDWR or O_CREAT
    when declared(O_NOFOLLOW):
      result = result or O_NOFOLLOW

proc livePidText(lockPath: string): string =
  ## The pid line of `lockPath` when it names a live process, "" otherwise
  ## (absent, unparseable, or dead). Dead or empty text in an unlocked
  ## file is never a lock.
  let owner = readOwnerPid(lockPath)
  var pid = -1
  try: pid = parseInt(owner) except ValueError: discard
  if pid > 0 and pidAlive(pid): owner else: ""

proc tryAcquireOsOwnership(lockPath, pid, sid, noun: string;
                           Err: typedesc[CatchableError]): LockAttempt =
  ## Take OS-level exclusive ownership of the persistent lock file at
  ## `lockPath`, creating it owner-only when missing. Returns taOwned with
  ## the ownership record the caller must keep until release. taHeld: the
  ## OS lock is held by someone. taLegacyHeld: the file is unlocked but
  ## its pid text names a live process - conservatively a legacy
  ## (pre-OS-lock) holder. Unexpected failures raise `Err`.
  when defined(posix):
    let fd = posix.open(lockPath.cstring, posixOpenFlags(), 0o600)
    if fd < 0:
      raise newException(Err, "could not create " & noun & " lock " &
        lockPath & ": " & osErrorMsg(osLastError()))
    # Children (bash tool, update worker) must not retain our ownership:
    # close the descriptor at exec even when the fork happens first.
    discard fcntl(fd, F_SETFD, FD_CLOEXEC)
    var err = OSErrorCode(0)
    while true:
      if c_flock(fd, LOCK_EX or LOCK_NB) == 0: break
      err = osLastError()
      if err.int32 == EINTR.int32: continue
      discard posix.close(fd)
      if err.int32 == EWOULDBLOCK.int32 or err.int32 == EAGAIN.int32:
        return LockAttempt(kind: taHeld, ownerPid: readOwnerPid(lockPath),
                           ownerSession: readOwnerSessionId(lockPath))
      raise newException(Err, "could not lock " & noun & " lock " &
        lockPath & ": " & osErrorMsg(err))
    var own = LockOwnership(path: lockPath, fd: fd)
  else:
    let h = winlean.createFileW(newWideCString(lockPath),
                                WinGenericReadWrite, WinShareRead, nil,
                                WinOpenAlways, WinFileAttributeNormal, 0)
    if h == winlean.INVALID_HANDLE_VALUE:
      let err = osLastError()
      if err.int32 == WinSharingViolation:
        return LockAttempt(kind: taHeld, ownerPid: readOwnerPid(lockPath),
                           ownerSession: readOwnerSessionId(lockPath))
      raise newException(Err, "could not create " & noun & " lock " &
        lockPath & ": " & osErrorMsg(err))
    var own = LockOwnership(path: lockPath, handle: h)
  # The OS lock is ours. An unlocked file that still names a live pid was
  # written by a legacy binary that holds it create-style (or, rarely, a
  # recycled pid): refuse instead of taking ownership. Only after that
  # check is our own owner record published.
  let legacy = livePidText(lockPath)
  if legacy.len > 0:
    closeOwnership(own)
    return LockAttempt(kind: taLegacyHeld, ownerPid: legacy,
                       ownerSession: readOwnerSessionId(lockPath))
  publishOwnerInfo(own, ownerRecord(pid, sid))
  LockAttempt(kind: taOwned, owned: own)

proc findOwned(reg: seq[LockOwnership]; lockPath: string): int =
  for i in 0 ..< reg.len:
    if reg[i].path == lockPath: return i
  -1

proc releaseOwnedAt(reg: var seq[LockOwnership]; i: int) =
  closeOwnership(reg[i])
  reg.delete(i)

proc acquireSessionLock*(path: string) =
  ## Claim the session lock for `path`, or raise SessionLocked.
  ##
  ## The persistent lock file's OS lock decides ownership: a file whose
  ## creator died is unlocked and acquires immediately (metadata republished
  ## in place, file never deleted); a file whose OS lock is held by anyone -
  ## including this process, including a holder that has not published its
  ## owner record yet - refuses with the holder's diagnostics. Releasing
  ## then reacquiring in one process works; acquiring a second session lock
  ## while one is held adds to this process's ownership instead of leaking
  ## the first handle.
  if path == "": return
  let dir = sessionLockDir()
  try: createDir(dir) except OSError: discard
  restrictLockDir(dir)
  let lockPath = sessionLockPathFor(path)
  let att = tryAcquireOsOwnership(lockPath, $getCurrentProcessId(), "",
                                  "session", SessionLocked)
  case att.kind
  of taOwned:
    ownedSessionLocks.add att.owned
  of taHeld, taLegacyHeld:
    raise lockHeldError(path, lockPath, att.ownerPid)

proc releaseSessionLock*(path: string) =
  ## Release the session lock for `path` if - and only if - this process
  ## owns it. A mismatched or repeated release does nothing: no other
  ## owner's lock is unlocked or deleted.
  if path == "": return
  let i = findOwned(ownedSessionLocks, sessionLockPathFor(path))
  if i >= 0: releaseOwnedAt(ownedSessionLocks, i)

proc releaseActiveSessionLock*() =
  ## Release every session lock this process owns. Idempotent.
  while ownedSessionLocks.len > 0:
    releaseOwnedAt(ownedSessionLocks, ownedSessionLocks.len - 1)

# ---------------------------------------------------------------------------
# Directory locks.
#
# Only one 3code process may hold a given working directory at a time. The
# lock is keyed by the collision-free mangled cwd (same scheme as the cwd
# session index and the pending draft path) so distinct directories never
# share a lock, and uses the same retained-OS-lock ownership as the
# session lock above. Dir locks carry a session-id line in their owner
# record so a collision report can name the holder's session. Directory
# and session locks are independent records: one process holds both for
# its live session.
# ---------------------------------------------------------------------------

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

proc probeOsLockHeld(lockPath: string): bool =
  ## True when someone holds the OS-level exclusive lock on `lockPath`.
  ## Probing ownership without stealing it: the file is never created,
  ## written, truncated, or deleted, and the probe never blocks.
  if not fileExists(lockPath): return false
  when defined(posix):
    let fd = posix.open(lockPath.cstring, O_RDWR, 0)
    if fd < 0: return false   # unreadable to us; not ours to claim
    var held = false
    while true:
      if c_flock(fd, LOCK_EX or LOCK_NB) == 0:
        discard posix.close(fd)   # drop the probe's own lock at once
        break
      let err = osLastError()
      if err.int32 == EINTR.int32: continue
      held = err.int32 == EWOULDBLOCK.int32 or err.int32 == EAGAIN.int32
      discard posix.close(fd)
      break
    held
  else:
    # An exclusive open is refused with a sharing violation exactly while
    # the owner's handle exists.
    let h = winlean.createFileW(newWideCString(lockPath),
                                WinGenericReadWrite, WinShareReadWrite, nil,
                                WinOpenExisting, WinFileAttributeNormal, 0)
    if h == winlean.INVALID_HANDLE_VALUE:
      osLastError().int32 == WinSharingViolation
    else:
      discard winlean.closeHandle(h)
      false

proc probeDirLockHeld*(cwd: string): string =
  ## Advisory, non-acquiring check for a live holder of `cwd`'s dir lock:
  ## returns the DirLocked message `acquireDirLock` would die with, or ""
  ## when the directory is free. The OS lock is the authority: stale text
  ## in an unlocked persistent file never counts as a live lock (a live
  ## pid there still does, as a possible legacy holder). `-r` startup runs
  ## this before session lookup so a running 3code is reported before
  ## "no saved sessions"; enforcement itself stays in `acquireDirLock`.
  if cwd == "": return
  let lockPath = dirLockPathFor(cwd)
  if probeOsLockHeld(lockPath) or livePidText(lockPath).len > 0:
    result = lockHeldDirError(cwd, lockPath, readOwnerPid(lockPath),
                              readOwnerSessionId(lockPath)).msg

proc acquireDirLock*(cwd: string; sessionPath = "") =
  ## Claim the directory lock for `cwd`, or raise DirLocked. Same
  ## retained-OS-lock ownership as `acquireSessionLock`: an owner that
  ## died unlocks the file for the next claimant in place, and a held
  ## lock refuses regardless of what text the file carries.
  ## `sessionPath`, when known, is recorded in the owner record so the
  ## collision error can name the holder's session instead of a bare pid.
  if cwd == "": return
  let dir = dirLockDir()
  try: createDir(dir) except OSError: discard
  restrictLockDir(dir)
  let lockPath = dirLockPathFor(cwd)
  let sid = sessionIdFromPath(sessionPath)
  let att = tryAcquireOsOwnership(lockPath, $getCurrentProcessId(), sid,
                                  "directory", DirLocked)
  case att.kind
  of taOwned:
    ownedDirLocks.add att.owned
  of taHeld, taLegacyHeld:
    raise lockHeldDirError(cwd, lockPath, att.ownerPid, att.ownerSession)

proc releaseDirLock*(cwd: string) =
  ## Release the directory lock for `cwd` if - and only if - this process
  ## owns it. Mismatched and repeated releases are no-ops.
  if cwd == "": return
  let i = findOwned(ownedDirLocks, dirLockPathFor(cwd))
  if i >= 0: releaseOwnedAt(ownedDirLocks, i)

proc releaseActiveDirLock*() =
  ## Release every directory lock this process owns. Idempotent.
  while ownedDirLocks.len > 0:
    releaseOwnedAt(ownedDirLocks, ownedDirLocks.len - 1)

proc updateActiveDirLockSession*(sessionPath: string) =
  ## Rewrite the owner record of the dir lock this process holds, for when
  ## the live session id moves (:clear forks a fresh one). Keeping it
  ## current means a collision report from another process never names a
  ## session this process has already abandoned. Best-effort: a failed
  ## rewrite only means the report falls back to the previous id.
  if ownedDirLocks.len == 0: return
  try:
    publishOwnerInfo(ownedDirLocks[^1],
      ownerRecord($getCurrentProcessId(), sessionIdFromPath(sessionPath)))
  except CatchableError: discard

proc listSessionPaths*(): seq[string] =
  ## Every managed transcript, plain and private, newest-first. The
  ## listing stays one merge: `:sessions`, `-l`, and `--find` all surface
  ## private sessions too (marked in display), while the sandbox keeps
  ## agents out of the directory itself.
  for d in [sessionDir(), privateSessionDir()]:
    if not dirExists(d): continue
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

proc goalVerdictWord*(v: GoalVerdictKind): string =
  ## The `goal_check` record's verdict spelling: `satisfied`, `feedback`,
  ## `cancelled`, or `none` (an informational step - the red "check
  ## unavailable" row included, since a check without a verdict is a
  ## failed check).
  case v
  of gvkSatisfied: "satisfied"
  of gvkFeedback: "feedback"
  of gvkCancelled: "cancelled"
  of gvkNone: "none"

proc goalVerdictFromWord*(w: string): GoalVerdictKind =
  ## The load side of `goalVerdictWord`; an unknown word reads as `none`
  ## (the red icon), never as satisfied.
  case w
  of "satisfied": gvkSatisfied
  of "feedback": gvkFeedback
  of "cancelled": gvkCancelled
  else: gvkNone

type SessionSaveError* = object of CatchableError
  ## A transcript save failed. `path` names the save target; `committed`
  ## locates the failure relative to the atomic replace:
  ##
  ## * `committed == false`: the new transcript never replaced the old
  ##   one - the previous bytes at `path` are intact and reloadable, and
  ##   no staging file of the attempt is left behind.
  ## * `committed == true`: the new transcript is already in place at
  ##   `path`; only post-commit synchronization failed, so durability is
  ##   unconfirmed and the previous bytes are NOT preserved.
  path*: string
  committed*: bool

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
  # The mode-kickoff latch: once the kickoff stanza has reached the
  # model it must never be fed again on resume (the mode stays armed
  # and the end-call boundary goes straight to the check).
  if session.goalNotified: hdr.add " goal_notified=1"
  # The user-facing name rides the record body (spaces survive there); a
  # header arg would split on the first space of "Feature xyz".
  if session.name.len > 0: emitRecord s, hdr, session.name
  else: emitHeaderOnly s, hdr
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
  # Verifier steps interleave at their anchored position: after the
  # first `after` messages, exactly where the live session committed
  # them (the end-call boundary sits between the turn's final reply and
  # the harness continuation that may follow it). A step whose anchor
  # outlives the conversation (compaction shrank it behind the
  # session's back) is dropped rather than pinned to a wrong turn.
  var markIdx = 0
  template emitGoalChecksAfter(n: int) =
    while markIdx < session.goalSteps.len and session.goalSteps[markIdx].after <= n:
      let mark = session.goalSteps[markIdx]
      emitRecord s, "goal_check verdict=" & goalVerdictWord(mark.step.verdict),
                  mark.step.prose
      inc markIdx
  var msgIdx = 0
  for m in messages:
    let idx = msgIdx
    inc msgIdx
    if m.kind != JObject: continue
    case m{"role"}.getStr
    of "system":
      # Constructed from the profile at resume; never persisted (see the
      # module doc). Nothing to write for the wire shape either - the
      # loader backfills a system message at index 0.
      discard
    of "user":
      let c = m{"content"}
      # `+agent` marks a harness-autosent prompt (empty-reply steer): replay
      # renders it as a `»` agent-prompt item, never a user `❯` echo.
      # `+goal` narrows it to the goal-mode `⚑` marker.
      let hdr = if m{"agentSent"}.getBool(false):
        (if m{"goalSent"}.getBool(false): "user +agent +goal" else: "user +agent")
      else: "user"
      # Image-bearing user message: persist the text blocks, then one
      # `image` record per block naming the delivered file on disk and its
      # sha1 — never the base64. Resume re-embeds the exact bytes, so the
      # re-sent message hits the provider's prompt cache.
      if c != nil and c.kind == JArray:
        let (ctx, notes, body) = splitPreamble(userTextBlocks(c))
        if ctx.len > 0: emitRecord s, "context", ctx
        if notes.len > 0: emitRecord s, "project_notes", notes
        emitRecord s, hdr, body
        let imgDir = sessionImageDir(session.savePath)
        for b in c.getElems:
          if b{"type"}.getStr != "image_url": continue
          let r = imageRefFromUri(b{"image_url"}{"url"}.getStr)
          if r.fmt.len == 0 or r.data.len == 0: continue
          let sha = $secureHash(r.data)
          let p = imgDir / (sha[0 ..< 16] & "." & r.fmt)
          # The `image` record names the delivered file, so emit it only
          # once the file verifiably holds the bytes: a failed image write
          # propagates and fails the whole save (the previous transcript
          # stays intact) instead of committing a reference to missing
          # data. Images write before the transcript rename, so a crash in
          # between can strand an unreferenced image file, but never a
          # committed transcript whose images are missing.
          if not (fileExists(p) and getFileSize(p) == r.data.len):
            createDir(imgDir)
            writeFile(p, r.data)
          emitHeaderOnly s, &"image path={p} sha1={sha} fmt={r.fmt} " &
            &"size={r.w}x{r.h}"
      else:
        let raw = m{"content"}.getStr("")
        let (ctx, notes, body) = splitPreamble(raw)
        if ctx.len > 0: emitRecord s, "context", ctx
        if notes.len > 0: emitRecord s, "project_notes", notes
        emitRecord s, hdr, body
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
      # `+flail` marks a flail-noted result (the call executed; the note
      # rides on top of the content). The preceding `flail` record carries
      # the note itself so load can restore the field and the rebuilt
      # toolLog can strip the note back out of the output.
      let flailNote = m{"flailNote"}.getStr("")
      if flailNote.len > 0:
        emitRecord s, "flail " & id, flailNote
      var hdr = "tool_result " & id & " exit=" & $exitCode
      # `+agent` marks a harness-autosent note (an abort batch's unexecuted
      # remainder) so replay renders the `»` item the live path committed,
      # not a tool banner.
      if m{"agentSent"}.getBool(false): hdr.add " +agent"
      if flailNote.len > 0: hdr.add " +flail"
      emitRecord s, hdr, m{"content"}.getStr("")
    else: discard
    emitGoalChecksAfter(idx + 1)
  s

# ---------- save / load ----------


proc isInSessionDir(path: string): bool =
  ## True when `path` lives under a managed sessions directory (the plain
  ## one or the private one), i.e. when it should be (and can be) indexed
  ## for cwd lookup. A `-s /custom.3log` save target lives elsewhere and is
  ## deliberately left unindexed.
  pathUnderDir(path, sessionDir()) or isPrivateSessionPath(path)

type SaveFaultPhase* = enum
  ## Points inside `writeTranscriptAtomic` where a test build may inject
  ## a failure (`saveFaultHook`) that ordinary OS fixtures cannot
  ## reproduce portably: a short staging write, a flush/close error, a
  ## failure of the final replacement itself, and a parent-directory
  ## sync failure after the commit (POSIX).
  sfpStageWrite, sfpFlushClose, sfpBeforeReplace, sfpDirSync

var saveFaultHook*: proc (phase: SaveFaultPhase) {.gcsafe, raises: [CatchableError].}
  ## Test-only fault injection point; nil in production, so every call is
  ## a single pointer check.

template runSaveFault(phase: SaveFaultPhase) =
  if saveFaultHook != nil: saveFaultHook(phase)

when defined(posix):
  proc cRename(oldname, newname: cstring): cint {.
    importc: "rename", header: "<stdio.h>".}

proc replaceFileRenaming(source, dest: string) =
  ## Rename `source` over `dest` — the platform's atomic replacement
  ## primitive (POSIX rename(2); Windows MoveFileExW with
  ## MOVEFILE_REPLACE_EXISTING, verified to overwrite). Deliberately not
  ## `os.moveFile`: that falls back to copy-and-delete on POSIX, which
  ## would leave `dest` truncated instead of intact when a copy fails
  ## midway. Same directory, so no cross-device case exists to soften.
  when defined(windows):
    if moveFileExW(newWideCString(source), newWideCString(dest),
                   MOVEFILE_REPLACE_EXISTING) == 0:
      raiseOSError(osLastError(), $(source, dest))
  else:
    if cRename(source.cstring, dest.cstring) != 0:
      raiseOSError(osLastError(), $(source, dest))

proc syncStagedFile(f: File) =
  ## Push the staged payload through the C buffer into storage before the
  ## replacement, so the renamed transcript is never a torn file after a
  ## crash or power loss. Durability is promised on POSIX (fsync) and on
  ## Windows (FlushFileBuffers); both raise on failure, before any
  ## replacement happened.
  f.flushFile()
  when defined(posix):
    if posix.fsync(getOsFileHandle(f)) != 0:
      raiseOSError(osLastError(), "fsync")
  else:
    if flushFileBuffers(getOsFileHandle(f)) == 0:
      raiseOSError(osLastError(), "FlushFileBuffers")

proc syncParentDir(dir: string) =
  ## Best-effort durability for the rename itself: persist the directory
  ## entry so the replacement survives power loss too. Failures are
  ## swallowed by design — the commit point has already passed, the new
  ## transcript is the visible one, and raising here would falsely claim
  ## the old file was preserved. This is POSIX-only; on Windows the
  ## replacement is atomic but the directory entry is not force-persisted.
  when defined(posix):
    let fd = posix.open(dir.cstring, posix.O_RDONLY)
    if fd == -1: return
    discard posix.fsync(fd)
    discard posix.close(fd)

proc resolveSaveTarget(path: string): string =
  ## A symlinked `-s` target keeps the writeFile-era contract: the bytes
  ## land in the link's target and the link itself survives (rename does
  ## not follow a final symlink component, so the destination must be the
  ## resolved target, never the link). An existing resolvable link
  ## resolves fully; a dangling link — the first save through a fresh `-s`
  ## symlink — follows the link text so the target is created where it
  ## points, exactly like writeFile did. A link loop raises instead of
  ## silently redirecting the save.
  result = path
  for _ in 0 ..< 32:
    if not symlinkExists(result): return
    try: return expandFilename(result)
    except OSError: discard
    let raw = expandSymlink(result)
    result = if raw.isAbsolute: raw else: absolutePath(raw, result.parentDir)
  raise newException(OSError, "symlink chain at " & path & " does not resolve")

var saveFailureReported = false
  ## One stderr line per broken save target: checkpoint saves report the
  ## first failure and defer to the next save's outcome, instead of
  ## flooding every turn step with the same error. Any committed save
  ## resets it.

proc writeTranscriptAtomic(dest, payload: string; durable = true) =
  ## Replace `dest` with `payload` through a staging file: created as a
  ## unique sibling of `dest` (never a predictable `.tmp` name), opened
  ## exclusively with owner-only permissions from creation on POSIX (no
  ## umask exposure window for prompt contents), fully written, flushed,
  ## and only then renamed over `dest`. Every failure before the rename
  ## raises with `dest` untouched and the staging file removed; after the
  ## rename the commit point has passed and the parent-directory sync
  ## (POSIX, when `durable`) never raises. Drafts use `durable = false`:
  ## they are debounced keystroke shadows, not committed history.
  let (f, staging) = createTempFile("3code-", ".stage", dest.parentDir)
  var committed = false
  var closed = false
  try:
    # Two writes so a test fault between them leaves a partially staged
    # file, like a real short write would.
    f.write payload[0 ..< payload.len div 2]
    runSaveFault sfpStageWrite
    f.write payload[payload.len div 2 .. ^1]
    runSaveFault sfpFlushClose
    if durable: f.syncStagedFile else: f.flushFile()
    f.close()
    closed = true
    runSaveFault sfpBeforeReplace
    replaceFileRenaming(staging, dest)
    committed = true
    saveFailureReported = false
    if durable:
      when defined(posix):
        runSaveFault sfpDirSync
      syncParentDir(dest.parentDir)
  except CatchableError as e:
    if not closed:
      try: f.close() except CatchableError: discard
    if not committed:
      # Staging files are owned by this attempt alone; never sweep the
      # directory for other names.
      try: removeFile(staging) except OSError: discard
    var err = newException(SessionSaveError,
      (if committed:
         "transcript saved but durability is unconfirmed " &
         "(previous transcript not preserved): "
       else:
         "transcript save failed (previous transcript preserved): ") & e.msg)
    err.path = dest
    err.committed = committed
    raise err

proc indexTranscript(session: Session) =
  ## Append the resume-latest index entry, only ever after the transcript
  ## committed: a failed append never fails the save (the transcript IS
  ## written, reporting it as unwritten would lie). Membership is
  ## re-checked at every commit, so a lost or truncated entry is repaired
  ## by the next save. Skipped for out-of-tree `-s` targets and when cwd
  ## is empty (always set in normal use, `session.cwd = safeCwd()`).
  if session.cwd == "" or not isInSessionDir(session.savePath): return
  let id = sessionIdFromPath(session.savePath)
  if id in indexIdsAt(sessionPathIndexDir(), session.cwd): return
  if not appendSessionIndex(session.cwd, id):
    stderr.writeLine "3code: transcript saved, but the resume index could " &
      "not be updated"

proc saveSession*(session: Session, messages: JsonNode) =
  ## Render the transcript and atomically replace the `.3log`. Raises
  ## `SessionSaveError` on failure, with the previous transcript on disk
  ## byte-for-byte intact and reloadable; the in-memory conversation is
  ## unaffected and a later save can still commit it. Renders (and writes
  ## any new image files) before touching the destination, so a bad image
  ## never costs the old transcript.
  if session.savePath == "": return
  try:
    # Render (including any new image files) inside the guarded block, so
    # a render-time image write failure is a SessionSaveError like every
    # other save failure: nothing has touched the destination yet.
    let dest = resolveSaveTarget(session.savePath)
    createDir(dest.parentDir)
    writeTranscriptAtomic(dest, renderSession(session, messages))
  except SessionSaveError:
    raise
  except CatchableError as e:
    var err = newException(SessionSaveError,
      "could not save transcript " & session.savePath & ": " & e.msg)
    err.path = session.savePath
    err.committed = false
    raise err
  indexTranscript(session)

proc reportSaveFailure*(e: ref SessionSaveError) =
  ## Report a save failure once per failing streak; the next committed
  ## save clears the suppression (see `saveSessionReported`).
  if not saveFailureReported:
    saveFailureReported = true
    stderr.writeLine "3code: " & e.msg

proc saveSessionReported*(session: Session, messages: JsonNode) =
  ## Checkpoint save for turn loops and prompt submission: like
  ## `saveSession`, but a SessionSaveError is reported on stderr (once
  ## per failing streak) instead of raised - the conversation stays in
  ## memory and the next checkpoint retries. Not for shutdown paths,
  ## which report and release ownership regardless, nor for blocking
  ## library calls, which must expose the failure to their caller.
  try:
    saveSession(session, messages)
  except SessionSaveError as e:
    e.msg.add " - the transcript stays in memory and the next save retries"
    reportSaveFailure(e)

proc writeDraftAtomic(path, text: string) =
  ## Create parent dirs and atomically write `text` to `path`, staging
  ## through the same exclusive owner-only temp file the transcript uses:
  ## a draft holds typed prompt text, so it never sits in a predictable
  ## `.tmp` name under default umask permissions. Not fsynced (debounced
  ## keystroke shadow, not committed history).
  createDir(path.parentDir)
  writeTranscriptAtomic(path, text, durable = false)

proc removeIfExists(path: string) =
  if fileExists(path):
    try: removeFile(path) except OSError: discard

proc draftAtSentenceEnd*(text: string): bool =
  ## True when `text` ends at a sentence boundary: a terminal `.`, `!` or
  ## `?` optionally followed by trailing spaces, or a completed line (a
  ## trailing newline) in a multi-line buffer. This gates the debounced
  ## draft save — mid-sentence text is not worth a disk write, since the
  ## shutdown flush (`flushDraftNow`) still captures it on the way out.
  let n = text.len
  if n == 0: return false
  if text[n - 1] == '\n': return true
  var i = n - 1
  while i >= 0 and text[i] in {' ', '\t', '\r'}: dec i
  if i < 0: return false
  text[i] in {'.', '!', '?'}

proc saveDraft*(session: Session, text: string) =
  ## Persist the current prompt-editor text as an atomic draft sidecar so an
  ## unexpected shutdown never loses a half-typed prompt. Writes to whichever
  ## scope `currentDraftPath` picks (cwd-keyed pending before the first turn,
  ## session-id-keyed after). A blank draft removes the sidecar rather than
  ## leaving an empty file, so an idle editor produces no draft. No-op without
  ## a cwd to key on (and no savePath).
  if session.savePath == "" and session.cwd == "": return
  let path = currentDraftPath(session)
  # A buffer holding only a quit line is not a draft: quitting snapshots the
  # editor before teardown, and restoring ":q" would prefill the prompt with
  # a command that exits on submit. Persist "" so the sidecar is removed,
  # exactly like an idle editor.
  let draft = if isQuitLine(text): "" else: text
  if draft.len == 0:
    removeIfExists(path)
    return
  try:
    writeDraftAtomic(path, draft)
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

proc adoptPrivateTranscriptDir*(session: var Session): bool =
  ## Move the live session's saves into the private transcript directory,
  ## for when private mode turns on after the session already exists
  ## (`:private on`, `-p --resume`). The conversation keeps running in
  ## memory; the next save re-renders the whole transcript under the new
  ## path. One direction only: `:private off` never moves a transcript
  ## back out, so private turns can never land in the plain directory. An
  ## out-of-tree `-s /custom.3log` target is the user's explicit choice and
  ## stays put. Returns true when the path moved.
  if not privateMode or session.savePath == "": return false
  if not pathUnderDir(session.savePath, sessionDir()): return false
  clearDraft(session)
  releaseSessionLock(session.savePath)
  let oldPath = session.savePath
  session.savePath = newSessionPath()
  # A reserved-but-never-saved transcript (startup allocation, `:clear`)
  # has no content to keep in the plain directory; drop it so the move
  # does not strand a forever-empty `.3log` in the listing.
  if not hasSavedSession(oldPath):
    removeIfExists(oldPath)
  session.created = $now()
  session.cwd = safeCwd()
  acquireSessionLock(session.savePath)
  updateActiveDirLockSession(session.savePath)
  true

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

proc sweepQuitDrafts*() =
  ## Delete draft sidecars whose whole content is a quit line: the residue the
  ## teardown flush wrote while the editor still held the `:q` it was quitting
  ## with. Runs at startup before any restore reads the store. Deleting is
  ## safe where a stale editor buffer's would not be: the content proves there
  ## is no work to lose, since submitting such a line quits.
  for dir in [draftDir(), pendingDraftDir()]:
    if not dirExists(dir): continue
    for kind, path in walkDir(dir):
      if kind != pcFile or not path.endsWith(".prompt"): continue
      let content = try: readFile(path) except CatchableError: ""
      if isQuitLine(content):
        removeIfExists(path)

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
    var content = m{"content"}.getStr("")
    # A flail-noted call's content carries the note above the real result;
    # the toolLog (and every replay banner built from it) wants the bare
    # result, not the warning.
    let note = m{"flailNote"}.getStr("")
    if note.len > 0 and content.startsWith(note & "\n\n"):
      content = content.substr(note.len + 2)
    idToContent[m{"tool_call_id"}.getStr] = content
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
        command: if act.kind == akBash: act.body else: "",
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
  var pendingFlail = initTable[string, string]()
  var hasResolvedSystem = false
  for r in records:
    let (pos, kv, flags) = parseArgs(r.args)
    case r.role
    of "session":
      if pos.len > 0: sess.created = pos[0]
      if "profile" in kv: sess.profileName = kv["profile"]
      if "cwd" in kv: sess.cwd = kv["cwd"]
      if "prompt_identity" in kv:
        sess.promptState.identity = kv["prompt_identity"]
      if kv.getOrDefault("goal_notified") == "1":
        sess.goalNotified = true
      if r.body.len > 0: sess.name = r.body
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
      let msg = %{"role": %"user", "content": %content}
      if "agent" in flags: msg["agentSent"] = %true
      if "goal" in flags: msg["goalSent"] = %true
      messages.add msg
      lastAssistant = nil
    of "image":
      # Re-embed an image recorded after a user record: file present and
      # sha1 intact → the same data URI bytes the live turn sent (provider
      # prefix cache hit); anything else → a stale note in the text, no
      # block. Attach and screenshot sources are identical at this layer.
      if messages.len == 0 or
          messages[^1]{"role"}.getStr != "user": continue
      let um = messages[^1]
      let path = kv.getOrDefault("path")
      let sha = kv.getOrDefault("sha1").toLowerAscii
      let fmt = kv.getOrDefault("fmt")
      var ok = false
      if path.len > 0 and fmt.len > 0 and fileExists(path):
        try:
          if ($secureHashFile(path)).toLowerAscii == sha:
            if um{"content"}.kind != JArray:
              var arr = newJArray()
              arr.add %*{"type": "text", "text": um{"content"}.getStr}
              um["content"] = arr
            um{"content"}.add %*{"type": "image_url",
              "image_url": {"url": imageDataUri(path, fmt)}}
            ok = true
        except CatchableError:
          discard
      if not ok:
        let note = "\n[image stale: " & path.extractFilename & "]"
        if um{"content"}.kind == JArray:
          for b in um{"content"}.getElems:
            if b{"type"}.getStr == "text":
              b["text"] = %(b{"text"}.getStr & note)
              break
        else:
          um["content"] = %(um{"content"}.getStr & note)
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
    of "goal_check":
      # A verifier step at its scrollback position: after the messages
      # parsed so far. Written interleaved by renderSession, so the
      # count here reproduces the live anchor exactly.
      sess.goalSteps.add GoalStepRecord(
        after: messages.len,
        step: GoalStep(prose: r.body,
          verdict: goalVerdictFromWord(kv.getOrDefault("verdict"))))
    of "flail":
      # The flail note for the tool_result that follows it.
      if pos.len > 0: pendingFlail[pos[0]] = r.body
    of "tool_result":
      let id = if pos.len > 0: pos[0] else: ""
      let exitCode = try: parseInt(kv.getOrDefault("exit", "0"))
                     except ValueError: 0
      exitByCallId[id] = exitCode
      let msg = %{"role": %"tool", "tool_call_id": %id,
                 "content": %r.body}
      if "agent" in flags: msg["agentSent"] = %true
      if "flail" in flags and pendingFlail.hasKey(id):
        msg["flailNote"] = %pendingFlail[id]
      messages.add msg
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
    # The backfilled system message shifts every anchor the records
    # counted without it (new-format files carry no system record); a
    # legacy file's own system record already counted.
    for g in mitems(sess.goalSteps): inc g.after
  sess.toolLog = buildToolLogFromMessages(messages, exitByCallId)
  sess.plan = buildPlanFromMessages(messages, exitByCallId)
  (sess, messages)

# ---------- session listing helpers ----------

type SessionPreview* = object
  cwd*: string
  profile*: string
  msgCount*: int
  firstUser*: string
  name*: string

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
      if r.body.len > 0:
        result.name = r.body.replace("\n", " ").replace("\r", " ").strip
    of "system": inc result.msgCount
    of "user":
      inc result.msgCount
      if result.firstUser.len == 0:
        result.firstUser = stripPreamble(r.body).replace("\n", " ").replace("\r", " ").strip
    of "assistant", "tool_result":
      inc result.msgCount
    else: discard

proc sessionPathForId*(id: string): string =
  ## The managed path for a bare session id, plain or private directory,
  ## with or without the `.3log` extension. "" when no such file exists.
  for d in [sessionDir(), privateSessionDir()]:
    for name in [id & SessionExt, id]:
      let p = d / name
      if fileExists(p): return p
  ""

proc listSessionPathsForCwd*(cwd: string): seq[string] =
  ## Sessions saved under `cwd`, latest-first — read straight from the cwd
  ## index, so it never parses a `.3log`. A missing/stale index entry is
  ## skipped via the `fileExists` check (e.g. a session deleted on disk).
  for id in indexIdsAt(sessionPathIndexDir(), cwd):
    let p = sessionPathForId(id)
    if p.len > 0: result.add p

proc resolveSessionPath*(id: string, cwd = ""): string =
  ## `id` is bare (no extension), a full path, a unique prefix of a session
  ## id, or a session name (`:rename`, matched case-insensitively, exact
  ## before prefix). Returns "" if not found; raises `SessionAmbiguous`
  ## when a lookup matches several. Exact ids win over prefixes and
  ## prefixes win over names, so a timestamp-shaped query never resolves
  ## to a session merely named alike. Prefix and name matching scan the
  ## cwd's sessions when `cwd` is set (the same scope `:sessions` lists),
  ## else every managed transcript. When `id` is empty and `cwd` is set,
  ## returns the latest session for that cwd via the cwd index (no session
  ## parsed); with `cwd` unset, the latest of any via a plain directory
  ## listing.
  if id == "":
    let candidates =
      if cwd != "": listSessionPathsForCwd(cwd)
      else: listSessionPaths()
    if candidates.len == 0: return ""
    return candidates[0]
  if fileExists(id): return id
  block exactId:
    let exact = sessionPathForId(id)
    if exact != "": return exact
  let candidates =
    if cwd != "": listSessionPathsForCwd(cwd)
    else: listSessionPaths()
  var idHits, nameHits, namePrefixHits: seq[string]
  let lowId = id.toLowerAscii
  for p in candidates:
    # A timestamp prefix can never collide with a name match below: ids
    # are checked first and win outright.
    if sessionIdFromPath(p).startsWith(id):
      idHits.add p
      continue
    let name = previewSession(p).name.toLowerAscii
    if name.len == 0: continue
    if name == lowId: nameHits.add p
    elif name.startsWith(lowId): namePrefixHits.add p
  template pickStage(hits: seq[string], label: string): string =
    if hits.len == 1: return hits[0]
    if hits.len > 1:
      var ids: seq[string]
      for p in hits: ids.add sessionIdFromPath(p)
      raise newException(SessionAmbiguous,
        "ambiguous session " & label & " \"" & id & "\": " & ids.join(", "))
    ""
  discard pickStage(idHits, "id prefix")
  discard pickStage(nameHits, "name")
  discard pickStage(namePrefixHits, "name prefix")
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

proc lastAssistantUsage*(messages: JsonNode): Usage =
  ## Usage of the last assistant turn, read from the inline `usage` field
  ## `loadSessionFile` restores onto it. Zero when the conversation has
  ## no assistant turn (fresh session, or a legacy file saved before
  ## inline usage). Powers the token bar `:resume` paints.
  if messages == nil or messages.kind != JArray: return
  for i in countdown(messages.len - 1, 0):
    if messages[i].kind != JObject: continue
    if messages[i]{"role"}.getStr == "assistant":
      return usageFromJson(messages[i]{"usage"})

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
