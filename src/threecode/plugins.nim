#[ Out-of-tree plugin host: discovery, load, one dispatch thread.
##
## Plugins are C-ABI dynamic libraries (see pluginabi.nim for the
## contract) discovered in `userDataRoot()/lib` plus the system dirs.
## A hook fires only for libs that export it (`symAddr` probe at load).
##
## Threading: ALL plugin code runs on a single dedicated thread, one
## call at a time, in load order — never on the turn, net, or input
## threads. Sync hooks (prompt, system prompt, tool pre/result/exec)
## round-trip: the dispatcher builds the event in one heap block (no
## caller-stack pointers, so a timeout can abandon it safely), pushes
## a job, and waits on the condvar with a deadline. On timeout the
## default outcome applies, the lib takes a strike (3 = demoted for
## the session), and the abandoned block is freed by the plugin thread
## when the hook finally returns — the two sides never both touch it.
## Async hooks (turn/session/compact/file events) are small POD copies
## in a bounded FIFO, dropped-oldest under pressure.
##
## Memory rules follow netthread.nim's ORC law: no Nim string or ref
## crosses threads. Event blocks are raw `alloc0`/`dealloc` payloads;
## the plugin ABI is cstring+len views into them.
]##

import std/[algorithm, dynlib, json, locks, os, strformat, strutils, tables, times]
import types, util, pluginabi

# -- config surface ([plugins] section, :plugin command) ------------

var pluginsDisabledNames*: seq[string] = @[]
  ## `[plugins] disable = a, b` — plugin names (lib file stems) to skip.
var pluginsToolsEnabled*: bool = false
  ## `[plugins] tools = on` — the opt-in gate for registered model-
  ## facing tools. Off by default: every registered schema rides every
  ## model request (the tools array is stateless), so mounting is a
  ## standing token cost the user must ask for.
var pluginTraceOn*: bool = false
  ## `[plugins] debug = on` or `:plugin debug` — trace every call:
  ## payload sizes, verdicts, and diffs of anything a plugin mutated.
var pluginsLibOverride*: string = ""
  ## `[plugins] lib = path` — extra/alternative search dir (tests).

const
  CapPrompt = 1 shl 20        # 1 MB
  CapSysPrompt = 1 shl 19     # 512 KB
  CapArgs = 1 shl 18          # 256 KB
  CapToolResult = 1 shl 20    # 1 MB
  DefaultSyncMs = 2_000
  DefaultToolExecMs = 120_000
  StrikeLimit = 3
  AsyncQueueCap = 256
  TraceDiffLines = 40

proc syncTimeoutMs(): int =
  try: parseInt(getEnv("THREECODE_PLUGIN_SYNC_MS"))
  except CatchableError: DefaultSyncMs

proc toolExecTimeoutMs(declared: int32): int =
  if declared > 0: declared.int
  else:
    try: parseInt(getEnv("THREECODE_PLUGIN_TOOL_MS"))
    except CatchableError: DefaultToolExecMs

var pluginInterruptedProbe*: proc (): bool {.gcsafe.}
  ## Set by api.nim to `isInterrupted`; the sync wait loop polls it and
  ## flags the running call's `cancelled` field. A proc var rather
  ## than an import to avoid the api -> plugins -> api cycle.

proc pluginTrace(): bool {.inline.} =
  pluginTraceOn or debugEnabled

proc pdbg(msg: string) {.inline.} =
  if pluginTrace(): debugOutForced(msg, "plugin")

proc pdbg(msg, tag: string) {.inline.} =
  if pluginTrace(): debugOutForced(msg, tag)

proc lenCstring(cs: cstring): int {.inline.} =
  if cs == nil: 0 else: cs.len

proc setPluginTrace*(on: bool) =
  ## `:plugin debug on|off` — flip tracing in a running session.
  pluginTraceOn = on

# -- registry ------------------------------------------------------

type
  HookId* = enum
    hInit, hShutdown, hRegisterTools, hPrompt, hSysPrompt, hToolPre,
    hToolResult, hToolExec, hTurnStart, hTurnEnd, hRetry, hSession,
    hCompact, hFileWrite, hRegisterCli, hCliCommand, hCliOptions

  PluginTool* = object
    name*: string
    description*: string
    schema*: string          ## JSON text; parsed host-side on demand
    timeoutMs*: int32
    owner*: int              ## lib index

  PluginCliCommand* = object
    name*: string
    help*: string
    owner*: int              ## lib index

  PluginCliOption* = object
    longName*: string
    shortName*: char         ## '\0' when the option has no short form
    takesValue*: bool
    help*: string
    owner*: int              ## lib index

  PluginLib* = ref object
    name*: string
    handle*: LibHandle
    statePtr*: ptr TcState   ## heap TcState; addr given to the plugin
    servicesPtr*: ptr TcServices
    nameC*: cstring          ## backing for state.pluginName
    hooks*: array[HookId, pointer]
    strikes*: int
    demoted*: bool           ## sync hooks skipped for the session
    hookCalls*: int

  JobKind* = enum jkSync, jkAsync, jkShutdown
  Job* = ptr JobObj
  JobObj* = object
    kind*: JobKind
    libIdx*: int
    hook*: HookId
    ev*: pointer
    gen*: int64
    done*: bool
    abandoned*: bool

const HookSyms: array[HookId, string] = [
  "tc_init", "tc_shutdown", "tc_register_tools", "tc_on_prompt",
  "tc_on_system_prompt", "tc_on_tool_pre", "tc_on_tool_result",
  "tc_tool_exec", "tc_on_turn_start", "tc_on_turn_end",
  "tc_on_model_retry", "tc_on_session_start", "tc_on_compact",
  "tc_on_file_write", "tc_register_cli", "tc_cli_command",
  "tc_on_cli_options"]

# Names the option parser and the early subcommand dispatchers already
# own; a plugin CLI registration colliding with any of these is refused
# so `3code <word>` keeps meaning exactly one thing.
const BuiltinCliCommandNames* = [
  "good", "provider", "sandbox", "sb", "box", "wall", "stdio-relay",
  "setup", "unsetup"]
const BuiltinLongOptNames* = [
  "model", "config", "resume", "session", "interactive", "list", "all",
  "find", "page", "good", "experimental", "private", "computer",
  "no-sandbox", "debug", "version", "help", "acp"]
const BuiltinShortOptChars* = {'m', 's', 'c', 'r', 'i', 'l', 'a', 'f', 'p',
                               'g', 'x', 'D', 'v', 'h'}

var
  libs: seq[PluginLib]
  regTools: seq[PluginTool]
  regCliCommands: seq[PluginCliCommand]
  regCliOptions: seq[PluginCliOption]
  regGen = 0                 # bumped at registration; see regParsed
  regParsedGen = -1          # main-thread mirror of regGen
  regParsed: Table[string, JsonNode]
  loadNotes: seq[string]        # skipped libs + reasons, for :plugins
  hookLive: array[HookId, bool]
  sysPromptCache: Table[string, string]
  registeringLib = -1           # services.registerTool gate
  registeringCliLib = -1        # services.registerCli* gate
  started = false

  pLock: Lock
  pCond: Cond
  syncDispLock: Lock            # serializes dispatchers (one sync slot)
  queue: seq[Job]
  syncPending: Job
  jobGen: int64 = 0
  threadUp = false
  drainSeen = false
  pThread: Thread[void]

proc anyLive(h: HookId): bool {.inline.} = hookLive[h]

# -- raw block helpers (cross-thread free is plain C-heap) ----------

proc tcAlloc(n: int): cstring {.inline.} =
  result = cast[cstring](alloc0(max(1, n)))

proc tcFree(p: cstring) {.inline.} =
  if p != nil: dealloc(p)

proc viewFill(dst: var TcStr; s: string) {.inline.} =
  if s.len == 0:
    dst.data = tcAlloc(1)
    dst.len = 0
  else:
    dst.data = tcAlloc(s.len)
    copyMem(dst.data, addr s[0], s.len)
    dst.len = s.len.int32

proc mutFill(dst: var TcMutStr; s: string; cap: int) =
  ## Host-sized editable buffer: double the payload, floored at 16 KB,
  ## capped at the field maximum. A payload already over the cap means
  ## the hook is skipped by the caller (never truncated silently).
  dst.cap = min(cap, max(s.len * 2, 16 * 1024)).int32
  dst.data = tcAlloc(dst.cap.int)
  if s.len > 0: copyMem(dst.data, addr s[0], s.len)
  dst.len = s.len.int32

proc freeViews(ev: pointer; hook: HookId) =
  ## Frees every cstring inside an event block plus the block itself.
  ## Which fields are pointers is known per hook; keep in sync with
  ## pluginabi.nim.
  template f(p: cstring) = tcFree(p)
  case hook
  of hPrompt:
    let e = cast[ptr TcPromptEvent](ev)
    f(e.prompt.data); f(e.cwd.data); f(e.sessionPath.data)
    f(e.provider.data); f(e.model.data)
    dealloc(e)
  of hSysPrompt:
    let e = cast[ptr TcSysPromptEvent](ev)
    f(e.prompt.data); f(e.provider.data); f(e.model.data); f(e.family.data)
    dealloc(e)
  of hToolPre:
    let e = cast[ptr TcToolPreEvent](ev)
    f(e.name.data); f(e.args.data); f(e.callId.data); f(e.family.data)
    f(e.message.data); f(e.post.data)
    dealloc(e)
  of hToolResult:
    let e = cast[ptr TcToolResultEvent](ev)
    f(e.name.data); f(e.args.data); f(e.output.data); f(e.diff.data)
    dealloc(e)
  of hToolExec:
    let e = cast[ptr TcToolExecEvent](ev)
    f(e.name.data); f(e.args.data); f(e.output.data)
    dealloc(e)
  of hTurnStart:
    let e = cast[ptr TcTurnEvent](ev)
    f(e.cwd.data); dealloc(e)
  of hTurnEnd:
    let e = cast[ptr TcTurnEndEvent](ev)
    f(e.sessionPath.data); dealloc(e)
  of hRetry:
    let e = cast[ptr TcRetryEvent](ev)
    f(e.provider.data); f(e.model.data); f(e.category.data); dealloc(e)
  of hSession:
    let e = cast[ptr TcSessionEvent](ev)
    f(e.sessionPath.data); f(e.cwd.data); f(e.provider.data)
    f(e.model.data); dealloc(e)
  of hCompact:
    let e = cast[ptr TcCompactEvent](ev)
    f(e.summary.data); dealloc(e)
  of hFileWrite:
    let e = cast[ptr TcFileWriteEvent](ev)
    f(e.path.data); dealloc(e)
  of hCliCommand:
    let e = cast[ptr TcCliCommandEvent](ev)
    f(e.name.data); f(e.args.data); f(e.output.data); dealloc(e)
  of hCliOptions:
    let e = cast[ptr TcCliOptionsEvent](ev)
    f(e.options.data); dealloc(e)
  of hInit, hShutdown, hRegisterTools, hRegisterCli:
    discard  # no event block

# -- services (called on the plugin thread) -------------------------

proc noteLoad(msg: string) =
  pLock.acquire()
  loadNotes.add msg
  pLock.release()
  pdbg "plugin: " & msg

proc svcLog(s: ptr TcState; msg: cstring; len: int32) {.cdecl, gcsafe.} =
  if msg == nil or len <= 0: return
  let m = newString(len.int)
  copyMem(addr m[0], msg, len.int)
  pdbg(m, "plugin:" & $s.pluginName)

const BuiltinToolNames = [
  "bash", "sh", "shell", "read", "cat", "write", "edit", "patch",
  "apply_patch", "applypatch", "apply-patch", "plan", "update_plan",
  "todo", "dmail", "web_search", "search", "web_fetch", "fetch", "clear"]

proc svcRegisterTool(s: ptr TcState; name, description, schemaJson: cstring;
                     timeoutMs: int32): cint {.cdecl, gcsafe.} =
  {.cast(gcsafe).}:
    # Runs on the plugin thread during startup registration. regTools
    # is written here under pLock and read by main-thread readers via
    # snapshotTools(); the ORC rule (no shared GC'ed globals across
    # threads) is honored by never mutating without the lock and never
    # reading outside a locked copy.
    if registeringLib < 0: return 1.cint
    let n = tcView(TcStr(data: name, len: int32(lenCstring(name))))
    if n.len == 0: return 2.cint
    if n in BuiltinToolNames: return 3.cint
    for t in regTools:
      if t.name == n: return 4.cint
    let entry = PluginTool(
      name: n,
      description: tcView(TcStr(data: description, len: int32(lenCstring(description)))),
      schema: tcView(TcStr(data: schemaJson, len: int32(lenCstring(schemaJson)))),
      timeoutMs: timeoutMs, owner: registeringLib)
    pLock.acquire()
    regTools.add entry
    pLock.release()
    inc regGen
    hookLive[hToolExec] = true
    0.cint

proc cliNameOk(n: string): bool =
  n.len > 0 and n[0] != '-' and n.allCharsInSet({'a'..'z', '0'..'9', '-'})

proc svcRegisterCliCommand(s: ptr TcState; name, help: cstring): cint {.
    cdecl, gcsafe.} =
  {.cast(gcsafe).}:
    # See svcRegisterTool for the locking story: written on the plugin
    # thread under pLock, read by main-thread readers via copies.
    if registeringCliLib < 0: return 1.cint
    let n = tcView(TcStr(data: name, len: int32(lenCstring(name))))
    if not cliNameOk(n): return 2.cint
    if n in BuiltinCliCommandNames: return 3.cint
    pLock.acquire()
    for c in regCliCommands:
      if c.name == n:
        pLock.release()
        return 4.cint
    regCliCommands.add PluginCliCommand(
      name: n,
      help: tcView(TcStr(data: help, len: int32(lenCstring(help)))),
      owner: registeringCliLib)
    pLock.release()
    0.cint

proc svcRegisterCliOption(s: ptr TcState; longName, shortName, help: cstring;
                          takesValue: cint): cint {.cdecl, gcsafe.} =
  {.cast(gcsafe).}:
    if registeringCliLib < 0: return 1.cint
    let n = tcView(TcStr(data: longName, len: int32(lenCstring(longName))))
    let sh = tcView(TcStr(data: shortName, len: int32(lenCstring(shortName))))
    if not cliNameOk(n): return 2.cint
    if sh.len > 1: return 2.cint
    if n in BuiltinLongOptNames: return 3.cint
    let shortCh = if sh.len == 1: sh[0] else: '\0'
    if shortCh in BuiltinShortOptChars: return 3.cint
    pLock.acquire()
    for o in regCliOptions:
      if o.longName == n or
          (shortCh != '\0' and o.shortName == shortCh):
        pLock.release()
        return 4.cint
    regCliOptions.add PluginCliOption(
      longName: n,
      shortName: shortCh,
      takesValue: takesValue != 0,
      help: tcView(TcStr(data: help, len: int32(lenCstring(help)))),
      owner: registeringCliLib)
    pLock.release()
    0.cint

# -- plugin thread --------------------------------------------------

proc runHook(lib: PluginLib; hook: HookId; ev: pointer) =
  {.cast(gcsafe).}:
    inc lib.hookCalls
    let s = lib.statePtr
    try:
      case hook
      of hInit:
        if lib.hooks[hInit] != nil:
          discard cast[TcInitFn](lib.hooks[hInit])(s)
      of hShutdown:
        if lib.hooks[hShutdown] != nil:
          cast[TcVoidFn](lib.hooks[hShutdown])(s, nil)
      of hRegisterTools:
        if lib.hooks[hRegisterTools] != nil:
          registeringLib = libs.find(lib)
          cast[TcVoidFn](lib.hooks[hRegisterTools])(s, nil)
          registeringLib = -1
      of hRegisterCli:
        if lib.hooks[hRegisterCli] != nil:
          registeringCliLib = libs.find(lib)
          cast[TcVoidFn](lib.hooks[hRegisterCli])(s, nil)
          registeringCliLib = -1
      of hCliCommand:
        discard cast[TcIntFn](lib.hooks[hCliCommand])(s, ev)
      of hCliOptions:
        cast[TcVoidFn](lib.hooks[hCliOptions])(s, ev)
      of hToolPre:
        let e = cast[ptr TcToolPreEvent](ev)
        e.verdict = cast[TcIntFn](lib.hooks[hToolPre])(s, e)
      of hToolExec:
        discard cast[TcIntFn](lib.hooks[hToolExec])(s, ev)
      of hPrompt, hSysPrompt, hToolResult, hTurnStart, hTurnEnd, hRetry,
         hSession, hCompact, hFileWrite:
        cast[TcVoidFn](lib.hooks[hook])(s, ev)
    except CatchableError as e:
      # Never let a plugin exception escape into the host thread; the
      # trace channel is all the diagnosis a broken plugin gets.
      pdbg &"plugin {lib.name} hook {HookSyms[hook]} raised: {e.msg}"

proc pluginThreadMain() {.thread.} =
  {.cast(gcsafe).}:
    while true:
      var job: Job = nil
      pLock.acquire()
      while job == nil:
        if syncPending != nil:
          job = syncPending
          syncPending = nil
        elif queue.len > 0:
          job = queue[0]
          queue.delete(0)
        elif drainSeen:
          break
        else:
          wait(pCond, pLock)
      pLock.release()
      if job == nil: return
      if job.kind == jkAsync:
        for lib in libs:
          if lib.hooks[job.hook] != nil:
            runHook(lib, job.hook, job.ev)
        freeViews(job.ev, job.hook)
        dealloc(job)
      else:
        let lib =
          if job.libIdx >= 0 and job.libIdx < libs.len: libs[job.libIdx]
          else: nil
        pLock.acquire()
        let stale = job.abandoned or lib == nil
        pLock.release()
        if stale:
          if job.kind == jkSync: freeViews(job.ev, job.hook)
          dealloc(job)
          continue
        runHook(lib, job.hook, job.ev)
        if job.kind == jkShutdown:
          # no waiter: the enqueuer only joins the thread
          dealloc(job)
          continue
        pLock.acquire()
        job.done = true
        let ab = job.abandoned
        pLock.release()
        if ab:
          if job.kind == jkSync: freeViews(job.ev, job.hook)
          dealloc(job)
        else:
          pCond.signal()

# -- sync dispatch --------------------------------------------------

proc syncCall(libIdx: int; hook: HookId; ev: pointer; timeoutMs: int): bool =
  ## Runs one hook on the plugin thread and waits. False = completed
  ## (the event block is again caller-owned). True = timed out and
  ## abandoned: the block now belongs to the plugin thread; the caller
  ## must not read or free it, and the default outcome applies.
  if not threadUp: return false
  syncDispLock.acquire()
  defer: syncDispLock.release()
  pLock.acquire()
  if libIdx < 0 or libIdx >= libs.len: pLock.release(); return false
  let lib = libs[libIdx]
  if lib.demoted or lib.hooks[hook] == nil:
    pLock.release(); return false
  inc jobGen
  let job = cast[Job](alloc0(sizeof(JobObj)))
  job[] = JobObj(kind: jkSync, libIdx: libIdx, hook: hook, ev: ev,
                 gen: jobGen)
  lib.statePtr.cancelled = 0
  syncPending = job
  pCond.signal()
  pLock.release()
  # No timed condvar wait in this Nim's std/locks: poll `done` on a
  # 2ms slice. Sync hooks fire per prompt / tool call, not per token,
  # so the poll cost is noise against the plugin round trip itself.
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while true:
    pLock.acquire()
    if job.done:
      syncPending = nil
      pLock.release()
      dealloc(job)
      return false
    pLock.release()
    if pluginInterruptedProbe != nil and pluginInterruptedProbe():
      lib.statePtr.cancelled = 1
    sleep(2)
    if epochTime() >= deadline: break
  # deadline passed without done: abandon. The plugin thread frees the
  # job and the event block when the hook eventually returns.
  pLock.acquire()
  if job.done:
    pLock.release()
    dealloc(job)
    return false
  job.abandoned = true
  if syncPending == job: syncPending = nil
  lib.statePtr.cancelled = 1  # let a long hook wind down early
  inc lib.strikes
  let demoteNow = lib.strikes >= StrikeLimit and not lib.demoted
  if demoteNow: lib.demoted = true
  pLock.release()
  if demoteNow:
    noteLoad &"{lib.name}: demoted after {lib.strikes} slow calls " &
      "(sync hooks skipped for this session)"
  pdbg &"plugin {lib.name}: hook {HookSyms[hook]} timed out " &
    "after " & $timeoutMs & "ms (strike " & $lib.strikes & "/" &
    $StrikeLimit & ")"
  true

# -- debug trace helpers --------------------------------------------

proc plainDiff(a, b: string): string =
  ## First-order line diff: shared prefix, shared suffix, middle
  ## rendered as -old/+new rows. Debug-only, so no Myers — the common
  ## case (a plugin edited a few lines) reads fine.
  let al = a.splitLines
  let bl = b.splitLines
  var pre = 0
  while pre < al.len and pre < bl.len and al[pre] == bl[pre]: inc pre
  var suf = 0
  while suf < al.len - pre and suf < bl.len - pre and
      al[al.len - 1 - suf] == bl[bl.len - 1 - suf]: inc suf
  var lines: seq[string]
  for i in pre ..< al.len - suf:
    lines.add "-" & (if al[i].len > 120: al[i][0 ..< 120] & "…" else: al[i])
  for i in pre ..< bl.len - suf:
    lines.add "+" & (if bl[i].len > 120: bl[i][0 ..< 120] & "…" else: bl[i])
  if lines.len > TraceDiffLines:
    let more = lines.len - TraceDiffLines
    lines = lines[0 ..< TraceDiffLines]
    lines.add &"... {more} more"
  if lines.len == 0: "unchanged" else: lines.join(" | ")

proc traceHook(lib: PluginLib; hook: HookId; ms: float) =
  pdbg &"{HookSyms[hook]} {lib.name} {ms:.1f}ms"

# -- public host API ------------------------------------------------

var condInitDone = false

proc initCondAndLocksOnce() =
  if condInitDone: return
  condInitDone = true
  initLock(pLock)
  initLock(syncDispLock)
  initCond(pCond)

proc pluginsDiscoverAndLoad*() =
  ## Scan the lib dirs once at startup and start the plugin thread.
  ## Safe to call from both the CLI and library entry points; guarded.
  if started: return
  started = true
  initCondAndLocksOnce()
  var dirs: seq[string]
  if pluginsLibOverride.len > 0: dirs.add pluginsLibOverride
  dirs.add userDataRoot() / "lib"
  when defined(posix):
    dirs.add "/usr/local/lib/3code"
    dirs.add "/usr/lib/3code"
  else:
    dirs.add getEnv("ProgramFiles") / "3code" / "lib"
  const ext = when defined(windows): ".dll"
               elif defined(macosx): ".dylib"
               else: ".so"
  var seen: seq[string]
  var candidates: seq[tuple[path, name: string]]
  for d in dirs:
    if not dirExists(d): continue
    var names: seq[string]
    for k, f in walkDir(d):
      if k != pcFile: continue
      if not f.endsWith(ext): continue
      names.add f
    names.sort()
    for f in names:
      let stem = splitFile(f).name
      if stem in seen: continue
      seen.add stem
      candidates.add (f, stem)
  var loaded: seq[PluginLib]
  for (path, stem) in candidates:
    if stem in pluginsDisabledNames:
      noteLoad stem & ": disabled by [plugins] disable"
      continue
    let handle = loadLib(path)
    if handle == nil:
      noteLoad stem & ": loadLib failed (" & path & ")"
      continue
    template sym(n: string): pointer = symAddr(handle, n)
    let versionSym = sym("tc_abi_version")
    if versionSym == nil:
      noteLoad stem & ": no tc_abi_version export, skipped"
      unloadLib(handle)
      continue
    let version = cast[TcVersionFn](versionSym)()
    if version != TcAbiVersion:
      noteLoad stem & ": abi version " & $version & " != host " &
        $TcAbiVersion & ", skipped"
      unloadLib(handle)
      continue
    var lib = PluginLib(name: stem, handle: handle)
    for h in HookId:
      lib.hooks[h] = symAddr(handle, cstring(HookSyms[h]))
    lib.statePtr = cast[ptr TcState](alloc0(sizeof(TcState)))
    lib.servicesPtr = cast[ptr TcServices](alloc0(sizeof(TcServices)))
    lib.servicesPtr[] = TcServices(
      log: svcLog,
      registerTool: svcRegisterTool,
      registerCliCommand: svcRegisterCliCommand,
      registerCliOption: svcRegisterCliOption)
    lib.nameC = tcAlloc(stem.len + 1)
    copyMem(lib.nameC, unsafeAddr stem[0], stem.len)
    lib.statePtr[] = TcState(
      abi: TcAbiVersion,
      structSize: sizeof(TcState).int32,
      pluginName: lib.nameC,
      userData: nil,
      cancelled: 0,
      services: lib.servicesPtr)
    loaded.add lib
    pdbg &"plugin: loaded {stem} from {path}"
  libs = loaded
  for lib in libs:
    for h in HookId:
      if lib.hooks[h] != nil: hookLive[h] = true
  if libs.len == 0: return
  threadUp = true
  createThread(pThread, pluginThreadMain)
  # init + register on the plugin thread, synchronously: registerTool
  # is only legal there, and tool advertisement must be settled before
  # the first model call. A failed init demotes the lib instead of
  # dropping it from `libs` (indices must stay stable once the thread
  # is up; demoted libs are skipped everywhere).
  for i, lib in libs:
    if lib.hooks[hInit] == nil: continue
    if syncCall(i, hInit, nil, syncTimeoutMs()):
      lib.demoted = true
      noteLoad lib.name & ": tc_init timed out, skipped"
  # CLI registration must complete before pluginsDiscoverAndLoad
  # returns: the entry point parses argv right after and needs the
  # command/option tables. tc_on_cli_options (what the user actually
  # typed) fires later, once argv has been parsed.
  for i, lib in libs:
    if lib.hooks[hRegisterCli] != nil:
      if syncCall(i, hRegisterCli, nil, syncTimeoutMs()):
        noteLoad lib.name & ": tc_register_cli timed out"
  for i, lib in libs:
    if lib.hooks[hRegisterTools] != nil:
      if syncCall(i, hRegisterTools, nil, syncTimeoutMs()):
        noteLoad lib.name & ": tc_register_tools timed out"
  if regTools.len > 0 and not pluginsToolsEnabled:
    pdbg &"plugins: {regTools.len} registered tool(s) present but " &
      "[plugins] tools is off; not advertising"

proc pluginsShutdown*() =
  ## Drain, call tc_shutdown on the plugin thread, join, unload.
  if not started or not threadUp: return
  pLock.acquire()
  for i, lib in libs:
    if lib.hooks[hShutdown] != nil:
      let job = cast[Job](alloc0(sizeof(JobObj)))
      job[] = JobObj(kind: jkShutdown, libIdx: i, hook: hShutdown)
      queue.add job
  drainSeen = true
  pCond.signal()
  pLock.release()
  joinThread(pThread)
  threadUp = false
  for lib in libs: unloadLib(lib.handle)

proc pluginsLoadedCount*(): int =
  if started: libs.len else: 0

proc snapshotTools(): seq[PluginTool] =
  ## Locked copy for main-thread readers (registration happens on the
  ## plugin thread; see svcRegisterTool).
  pLock.acquire()
  result = regTools
  pLock.release()

proc toolOwner(name: string): int =
  for t in snapshotTools():
    if t.name == name: return t.owner
  -1

proc pluginCliCommands*(): seq[PluginCliCommand] =
  ## Locked copy for the entry point (usage rendering, dispatch).
  pLock.acquire()
  result = regCliCommands
  pLock.release()

proc pluginCliOptions*(): seq[PluginCliOption] =
  pLock.acquire()
  result = regCliOptions
  pLock.release()

proc pluginCliHasCommand*(name: string): bool =
  for c in pluginCliCommands():
    if c.name == name: return true
  false

proc pluginCliFindOption*(longName: string; short: char): int =
  ## Index into pluginCliOptions() for the given long name (short =
  ## '\0') or short char (longName = ""), -1 when no plugin owns it.
  for i, o in pluginCliOptions():
    if longName != "" and o.longName == longName: return i
    if longName == "" and short != '\0' and o.shortName == short: return i
  -1

proc pluginCliValueShorts*(): set[char] =
  ## Short flags of registered value-taking plugin options; the
  # entry point's attached-value expander needs them (`-zvalue`).
  for o in pluginCliOptions():
    if o.takesValue and o.shortName != '\0': result.incl o.shortName

proc pluginCliRunCommand*(name: string;
    args: seq[string]): tuple[output: string; code: int] =
  ## Runs a registered plugin subcommand on its owning lib. The
  ## budget is the tool-exec one: a subcommand is expected to take as
  ## long as a tool call. Host-side failures die() (they are usage/
  ## health errors, not the plugin's exit status); the plugin's own
  ## output and exit code come back for the caller to print and quit.
  var owner = -1
  for c in pluginCliCommands():
    if c.name == name:
      owner = c.owner
      break
  if owner < 0: die("no plugin owns command '" & name & "'", ExitUsage)
  if libs[owner].demoted:
    die("plugin owning '" & name & "' was demoted (too slow)", ExitConfig)
  var argv = newJArray()
  for a in args: argv.add %a
  let ev = cast[ptr TcCliCommandEvent](alloc0(sizeof(TcCliCommandEvent)))
  ev[] = TcCliCommandEvent(abi: TcAbiVersion,
                           structSize: sizeof(TcCliCommandEvent).int32)
  viewFill(ev.name, name)
  viewFill(ev.args, $argv)
  mutFill(ev.output, "", CapToolResult)
  ev.code = 0
  let t0 = epochTime()
  if syncCall(owner, hCliCommand, ev, toolExecTimeoutMs(0)):
    die("plugin command '" & name & "' timed out", 1)
  traceHook(libs[owner], hCliCommand, (epochTime() - t0) * 1000)
  result = (tcView(ev.output), ev.code.int)
  freeViews(ev, hCliCommand)

proc pluginsDeliverCliOptions*(vals: seq[(string, string)]) =
  ## Fires tc_on_cli_options on every subscribed lib with the options
  ## collected from argv: JSON object, value string for value options
  ## and true for flags. No-op when nothing was collected.
  if vals.len == 0: return
  if not hookLive[hCliOptions]: return
  var obj = newJObject()
  let opts = pluginCliOptions()
  for (n, v) in vals:
    var takesValue = true
    for o in opts:
      if o.longName == n: takesValue = o.takesValue
    obj[n] = (if takesValue and v != "": %v else: %true)
  let text = $obj
  if text.len > CapArgs:
    pdbg "plugins: cli options over cap, delivery skipped"
    return
  let ev = cast[ptr TcCliOptionsEvent](alloc0(sizeof(TcCliOptionsEvent)))
  ev[] = TcCliOptionsEvent(abi: TcAbiVersion,
                           structSize: sizeof(TcCliOptionsEvent).int32)
  viewFill(ev.options, text)
  for i in 0 ..< libs.len:
    let t0 = epochTime()
    if syncCall(i, hCliOptions, ev, syncTimeoutMs()): break
    traceHook(libs[i], hCliOptions, (epochTime() - t0) * 1000)
  freeViews(ev, hCliOptions)

proc pluginsHaveTool*(name: string): bool =
  if not pluginsToolsEnabled: return false
  for t in snapshotTools():
    if t.name == name: return true
  false

proc pluginToolSchemas*(): JsonNode =
  ## Registered tool schemas as a JArray (empty when the gate is off).
  ## Parsing happens host-side from the schema text registered on the
  ## plugin thread; JsonNodes never cross threads. setup() calls this
  ## from the turn thread AND the net worker, so the cache is guarded
  ## by pLock like every other cross-thread global here.
  result = newJArray()
  if not pluginsToolsEnabled: return
  var tools: seq[PluginTool]
  pLock.acquire()
  tools = regTools
  if regParsedGen != regGen:
    # a plugin registered (or re-registered) tools since the last
    # parse; rebuild the cache
    regParsed.clear()
    regParsedGen = regGen
  for t in tools:
    if t.name notin regParsed:
      try: regParsed[t.name] = parseJson(t.schema)
      except CatchableError:
        regParsed[t.name] = newJNull()
        pLock.release()
        noteLoad &"tool {t.name}: schema is not valid JSON, not advertised"
        pLock.acquire()
    if regParsed[t.name].kind != JObject: continue
    result.add regParsed[t.name]
  pLock.release()

proc pluginSystemPrompt*(base, provider, model, family: string): string =
  ## `tc_on_system_prompt` with memoization per (provider, model,
  ## family): setup() runs on every model call, the hook runs once per
  ## profile switch. Cache lives under pLock (netthread reads it).
  if not anyLive(hSysPrompt): return base
  let key = provider & "|" & model & "|" & family
  pLock.acquire()
  if key in sysPromptCache:
    let hit = sysPromptCache[key]
    pLock.release()
    return hit
  pLock.release()
  if base.len > CapSysPrompt:
    pdbg "plugins: system prompt over cap, hook skipped"
    return base
  let ev = cast[ptr TcSysPromptEvent](alloc0(sizeof(TcSysPromptEvent)))
  ev[] = TcSysPromptEvent(abi: TcAbiVersion,
                          structSize: sizeof(TcSysPromptEvent).int32)
  mutFill(ev.prompt, base, CapSysPrompt)
  viewFill(ev.provider, provider)
  viewFill(ev.model, model)
  viewFill(ev.family, family)
  var ok = true
  for i in 0 ..< libs.len:
    let t0 = epochTime()
    if syncCall(i, hSysPrompt, ev, syncTimeoutMs()):
      ok = false
      break
    traceHook(libs[i], hSysPrompt, (epochTime() - t0) * 1000)
    if pluginTrace():
      let now = tcView(ev.prompt)
      if now != base:
        pdbg "system prompt diff: " & plainDiff(base, now)
  let outPrompt = if ok: tcView(ev.prompt) else: base
  if ok:
    freeViews(ev, hSysPrompt)
    pLock.acquire()
    sysPromptCache[key] = outPrompt
    pLock.release()
  outPrompt

proc pluginOnPrompt*(text: var string; sessionPath, provider, model: string) =
  if not anyLive(hPrompt): return
  if text.len > CapPrompt:
    pdbg "plugins: prompt over cap, hook skipped"
    return
  let ev = cast[ptr TcPromptEvent](alloc0(sizeof(TcPromptEvent)))
  ev[] = TcPromptEvent(abi: TcAbiVersion,
                       structSize: sizeof(TcPromptEvent).int32)
  mutFill(ev.prompt, text, CapPrompt)
  viewFill(ev.cwd, safeCwd())
  viewFill(ev.sessionPath, sessionPath)
  viewFill(ev.provider, provider)
  viewFill(ev.model, model)
  var ok = true
  for i in 0 ..< libs.len:
    let t0 = epochTime()
    if syncCall(i, hPrompt, ev, syncTimeoutMs()):
      ok = false
      break
    traceHook(libs[i], hPrompt, (epochTime() - t0) * 1000)
    if pluginTrace():
      let before = text
      let now = tcView(ev.prompt)
      if now != before:
        pdbg "prompt diff: " & plainDiff(before, now)
        text = now
  if ok:
    text = tcView(ev.prompt)
    freeViews(ev, hPrompt)
  # on timeout the whole chain is discarded: the block belongs to the
  # plugin thread, and the user's original text stands.

type
  ToolPreOutcomeKind* = enum
    tpkAllow, tpkVeto, tpkRewrite, tpkTakeover, tpkWrap, tpkTimeout
  ToolPreOutcome* = object
    kind*: ToolPreOutcomeKind
    args*: string          ## tpkRewrite: the rewritten args JSON
    note*: string          ## tpkVeto/tpkTakeover: result / note text
    post*: string          ## tpkWrap: post text (note holds pre)
    code*: int             ## tpkTakeover: exit code

proc pluginOnToolPre*(name: string; args: var string; callId, family: string): ToolPreOutcome =
  result = ToolPreOutcome(kind: tpkAllow, args: args)
  if not anyLive(hToolPre): return
  if args.len > CapArgs:
    pdbg "plugins: tool args over cap, hook skipped"
    return
  let ev = cast[ptr TcToolPreEvent](alloc0(sizeof(TcToolPreEvent)))
  ev[] = TcToolPreEvent(abi: TcAbiVersion,
                        structSize: sizeof(TcToolPreEvent).int32)
  viewFill(ev.name, name)
  mutFill(ev.args, args, CapArgs)
  viewFill(ev.callId, callId)
  viewFill(ev.family, family)
  ev.verdict = tcAllow
  mutFill(ev.message, "", 4096)
  mutFill(ev.post, "", 4096)
  var wrapsPre: seq[string]
  var wrapsPost: seq[string]
  var rewrote = false
  var ok = true
  var chainBroken = false
  for i in 0 ..< libs.len:
    let t0 = epochTime()
    ev.verdict = tcAllow
    if syncCall(i, hToolPre, ev, syncTimeoutMs()):
      ok = false
      break
    traceHook(libs[i], hToolPre, (epochTime() - t0) * 1000)
    if pluginTrace():
      pdbg &"tool_pre {name} verdict={ev.verdict}"
      let nowArgs = tcView(ev.args)
      if nowArgs != args:
        pdbg "args diff: " & plainDiff(args, nowArgs)
        args = nowArgs
    case ev.verdict
    of tcAllow: discard
    of tcVeto:
      result = ToolPreOutcome(kind: tpkVeto, note: tcView(ev.message))
      chainBroken = true
      break
    of tcRewrite:
      args = tcView(ev.args)
      rewrote = true
    of tcTakeover:
      result = ToolPreOutcome(kind: tpkTakeover,
                              note: tcView(ev.message), code: ev.code.int)
      chainBroken = true
      break
    of tcWrap:
      wrapsPre.add tcView(ev.message)
      wrapsPost.add tcView(ev.post)
    else:
      discard  # unknown verdict from a C plugin: treated as allow
  if chainBroken:
    if ok: freeViews(ev, hToolPre)
    return result
  if not ok:
    # timeout mid-chain: discard everything, safest default is allow
    # with the model's original arguments
    return ToolPreOutcome(kind: tpkTimeout, args: result.args)
    # ev block owned by the plugin thread; do not touch
  let finalArgs = tcView(ev.args)
  freeViews(ev, hToolPre)
  if wrapsPre.len > 0:
    return ToolPreOutcome(kind: tpkWrap, args: finalArgs,
                          note: wrapsPre.join("\n"), post: wrapsPost.join("\n"))
  if rewrote:
    return ToolPreOutcome(kind: tpkRewrite, args: finalArgs)
  result.args = finalArgs

proc pluginOnToolResult*(name, args: string; output: var string;
                         code: var int; elapsedMs: int; diff: string) =
  if not anyLive(hToolResult): return
  if output.len > CapToolResult:
    pdbg "plugins: tool output over cap, hook skipped"
    return
  let ev = cast[ptr TcToolResultEvent](alloc0(sizeof(TcToolResultEvent)))
  ev[] = TcToolResultEvent(abi: TcAbiVersion,
                           structSize: sizeof(TcToolResultEvent).int32)
  viewFill(ev.name, name)
  viewFill(ev.args, args)
  mutFill(ev.output, output, CapToolResult)
  var evCode = code.int32
  ev.code = addr evCode
  ev.elapsedMs = elapsedMs.int32
  viewFill(ev.diff, diff)
  var ok = true
  for i in 0 ..< libs.len:
    let t0 = epochTime()
    if syncCall(i, hToolResult, ev, syncTimeoutMs()):
      ok = false
      break
    traceHook(libs[i], hToolResult, (epochTime() - t0) * 1000)
    if pluginTrace():
      let now = tcView(ev.output)
      if now != output:
        pdbg "tool result diff: " & plainDiff(output, now)
        output = now
  if not ok: return  # original result stands; block owned by plugin thread
  output = tcView(ev.output)
  code = evCode.int
  freeViews(ev, hToolResult)

proc pluginToolExec*(name, args: string): tuple[output: string; code: int] =
  ## Runs a registered plugin tool on its owning lib. Long budget: a
  ## tool call is expected to take as long as a bash call; ESC sets the
  ## `cancelled` flag the plugin should poll (tcCancelled).
  let owner = toolOwner(name)
  if owner < 0: return ("error: no plugin owns tool '" & name & "'", 1)
  if libs[owner].demoted:
    return ("error: owning plugin was demoted (too slow)", 1)
  let declared = block:
    var ms: int32 = 0
    for t in snapshotTools():
      if t.name == name: ms = t.timeoutMs
    ms
  let ev = cast[ptr TcToolExecEvent](alloc0(sizeof(TcToolExecEvent)))
  ev[] = TcToolExecEvent(abi: TcAbiVersion,
                         structSize: sizeof(TcToolExecEvent).int32)
  viewFill(ev.name, name)
  viewFill(ev.args, args)
  mutFill(ev.output, "", CapToolResult)
  ev.code = 0
  let t0 = epochTime()
  if syncCall(owner, hToolExec, ev, toolExecTimeoutMs(declared)):
    return ("error: plugin tool '" & name & "' timed out", -1)
  traceHook(libs[owner], hToolExec, (epochTime() - t0) * 1000)
  result = (tcView(ev.output), ev.code.int)
  freeViews(ev, hToolExec)

# -- async events ---------------------------------------------------

proc fireAsync(hook: HookId; ev: pointer) =
  if not anyLive(hook): return
  let job = cast[Job](alloc0(sizeof(JobObj)))
  job[] = JobObj(kind: jkAsync, hook: hook, ev: ev)
  pLock.acquire()
  if queue.len >= AsyncQueueCap:
    # drop-oldest: observe hooks are advisory; a burst never blocks
    # or grows without bound. One note per drop.
    let old = queue[0]
    queue.delete(0)
    pLock.release()
    freeViews(old.ev, old.hook)
    dealloc(old)
    pdbg &"plugins: async queue full, dropped oldest {HookSyms[old.hook]}"
    pLock.acquire()
  queue.add job
  pCond.signal()
  pLock.release()

proc pluginOnTurnStart*(turn, promptTokens: int) =
  if not anyLive(hTurnStart): return
  let ev = cast[ptr TcTurnEvent](alloc0(sizeof(TcTurnEvent)))
  ev[] = TcTurnEvent(abi: TcAbiVersion,
                     structSize: sizeof(TcTurnEvent).int32,
                     turn: turn.int32, promptTokens: promptTokens.int32)
  viewFill(ev.cwd, safeCwd())
  fireAsync(hTurnStart, ev)

proc pluginOnTurnEnd*(turn, promptTokens, completionTokens, reasoningTokens,
                      elapsedMs: int; interrupted: bool; sessionPath: string) =
  if not anyLive(hTurnEnd): return
  let ev = cast[ptr TcTurnEndEvent](alloc0(sizeof(TcTurnEndEvent)))
  ev[] = TcTurnEndEvent(abi: TcAbiVersion,
                        structSize: sizeof(TcTurnEndEvent).int32,
                        turn: turn.int32, promptTokens: promptTokens.int32,
                        completionTokens: completionTokens.int32,
                        reasoningTokens: reasoningTokens.int32,
                        elapsedMs: elapsedMs.int32,
                        interrupted: (if interrupted: 1 else: 0))
  viewFill(ev.sessionPath, sessionPath)
  fireAsync(hTurnEnd, ev)

proc pluginOnModelRetry*(provider, model: string; status: int;
                         category: string; backoffS, attempt: int) =
  if not anyLive(hRetry): return
  let ev = cast[ptr TcRetryEvent](alloc0(sizeof(TcRetryEvent)))
  ev[] = TcRetryEvent(abi: TcAbiVersion,
                      structSize: sizeof(TcRetryEvent).int32,
                      status: status.int32, backoffS: backoffS.int32,
                      attempt: attempt.int32)
  viewFill(ev.provider, provider)
  viewFill(ev.model, model)
  viewFill(ev.category, category)
  fireAsync(hRetry, ev)

proc pluginOnSessionStart*(sessionPath, cwd, provider, model: string;
                           resumed: bool; messages: int) =
  if not anyLive(hSession): return
  let ev = cast[ptr TcSessionEvent](alloc0(sizeof(TcSessionEvent)))
  ev[] = TcSessionEvent(abi: TcAbiVersion,
                        structSize: sizeof(TcSessionEvent).int32,
                        resumed: (if resumed: 1 else: 0),
                        messages: messages.int32)
  viewFill(ev.sessionPath, sessionPath)
  viewFill(ev.cwd, cwd)
  viewFill(ev.provider, provider)
  viewFill(ev.model, model)
  fireAsync(hSession, ev)

proc pluginOnCompact*(before, after: int; summary: string) =
  if not anyLive(hCompact): return
  let ev = cast[ptr TcCompactEvent](alloc0(sizeof(TcCompactEvent)))
  ev[] = TcCompactEvent(abi: TcAbiVersion,
                        structSize: sizeof(TcCompactEvent).int32,
                        before: before.int32, after: after.int32)
  viewFill(ev.summary, summary)
  fireAsync(hCompact, ev)

proc pluginOnFileWrite*(path: string; bytes: int; kind: int) =
  if not anyLive(hFileWrite): return
  let ev = cast[ptr TcFileWriteEvent](alloc0(sizeof(TcFileWriteEvent)))
  ev[] = TcFileWriteEvent(abi: TcAbiVersion,
                          structSize: sizeof(TcFileWriteEvent).int32,
                          bytes: bytes.int32, kind: kind.int32)
  viewFill(ev.path, path)
  fireAsync(hFileWrite, ev)

# -- :plugins / :plugin ----------------------------------------------

proc pluginsListBody*(): string =
  ## Plain-text body for the `:plugins` command.
  let tools = snapshotTools()
  let cliCmds = pluginCliCommands()
  result = "plugins: " & $libs.len & " loaded, " &
    $tools.len & " registered tool(s), " &
    $cliCmds.len & " cli command(s), " &
    "tools gate " & (if pluginsToolsEnabled: "on" else: "off") & "\n"
  for lib in libs:
    var hooks: seq[string]
    for h in HookId:
      if h in {hInit, hShutdown, hRegisterTools, hRegisterCli}: continue
      if lib.hooks[h] != nil: hooks.add HookSyms[h][3 ..^ 1]
    result.add &"- {lib.name}: {lib.hookCalls} calls"
    if lib.strikes > 0:
      result.add &", {lib.strikes} strikes"
    if lib.demoted:
      result.add ", DEMOTED (sync hooks skipped)"
    result.add "\n  hooks: " & (if hooks.len > 0: hooks.join(", ") else: "(none)")
    result.add "\n"
  for t in snapshotTools():
    if t.owner >= 0 and t.owner < libs.len:
      result.add &"- tool {t.name} (plugin {libs[t.owner].name})\n"
  for c in cliCmds:
    if c.owner >= 0 and c.owner < libs.len:
      result.add &"- command {c.name} (plugin {libs[c.owner].name})\n"
  for n in loadNotes:
    result.add "- " & n & "\n"
  if libs.len == 0 and loadNotes.len == 0:
    result.add "(none installed — drop .so files in " &
      userDataRoot() / "lib" & ")\n"

