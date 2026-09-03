## Entry point and outer REPL loop.
##
## `main` parses CLI args, sets up the session, and runs the interactive loop.
## `turns.runTurns` is the inner driver: it calls the model, dispatches
## tool calls, updates the session, and handles compaction - repeating until
## the model emits no tool calls.
##
## Module graph overview::
##
##   threecode (entry)
##     ├── turns        turn lifecycle + API/tool orchestration
##     ├── api          HTTP + SSE streaming + spinner
##     ├── actions      tool_call JSON → Action → execute
##     ├── compact      supersede elision + LLM summarization
##     ├── session      .3log persistence (save + load)
##     ├── display      terminal rendering (markdown, token bar, replays)
##     ├── ui           REPL :commands + provider wizard
##     ├── config       config file parse + profile resolution
##     ├── prompts      KnownGoodCombos + per-family (prompt, tools)
##     ├── shell        shell command parsing for the read cache
##     ├── web          native web search + URL fetch
##     ├── update       background auto-update
##     ├── fatprompt    volatile prompt/token/ticker state and frame bytes
##     ├── util         string utils, ANSI palette, markdown helpers
##     ├── types        shared types + globals
##     └── minline      readline-style input

import std/[json, os, parseopt, strformat, strutils, tables, terminal, times]
import std/exitprocs
when defined(posix):
  import std/posix
import threecode/[types, util, prompts, shell, session, compact,
                  config, actions, api, display, ui, update, fatprompt,
                  toolstream, turns, transcript, sandbox, box, wall,
                  auth_xai, auth_openai]
when defined(windows):
  import threecode/streamexec  # for resolveBash, used by ensureBash
when not defined(android):
  import tinotify
else:
  # Termux/Android has no desktop notification service; tinotify
  # hard-errors on the OS family, so notifications no-op there.
  proc notify(app, title, body: string) = discard
import threecode/minline
import threecode/engine as termengine
import threecode/library
export types, util, prompts, shell, session, compact,
       config, actions, api, display, ui, fatprompt, toolstream, turns,
       transcript, library



when defined(startupTrace):
  # Runtime-initialized at module load so the baseline is process start;
  # const would demand a compile-time epochTime (fails on Windows cross).
  let StartupT0 = epochTime()
  # When THREECODE_TRACE_FILE is set, milestones append there instead of
  # stderr, so timing is captured even when stderr is a console that the
  # caller can't easily scrape (e.g. a manual launch in Windows Terminal).
  let StartupTraceFile = getEnv("THREECODE_TRACE_FILE")
  template startupTrace(label: string) =
    ## stderr timing probe, compiled in only with -d:startupTrace.
    let line = "[trace] " & label & " " &
      formatFloat(epochTime() - StartupT0, ffDecimal, 3) & "\n"
    if StartupTraceFile.len > 0:
      try:
        let f = open(StartupTraceFile, fmAppend)
        f.write(line)
        f.close()
      except CatchableError: discard
    else:
      stderr.write(line)
else:
  template startupTrace(label: string) = discard

proc usage() {.noreturn.} =
  stderr.writeLine """usage: 3code [options] [prompt...]
       3code good                   # list known-good provider/variant combos
       3code sandbox restrict DIR -- CMD   # run CMD sandboxed (alias: sb)
       3code setup                  # one-time elevated sandbox setup (Windows)

  -m, --model PROVIDER[.MODEL]   pick model from config (overrides [settings])
  -r, --resume[=ID]    resume latest session from this directory (or by id)
  -i, --interactive    drop into the REPL after running an initial prompt
                      (without it, a prompt runs once and exits)
  -l, --list           list recent sessions for this directory (max 20) and exit
  -a, --all            (reserved) with -l, accepted but a no-op for now
  -g, --good           list known-good provider/variant combos and exit
  -x, --experimental   allow combos outside the known-good list
      --no-sandbox     disable sandbox enforcement (bash runs unconfined)
  -D, --debug          colored debug trace to stderr
  -v, --version        print version
  -h, --help           this message

config: """ & configPath()
  quit ExitUsage


proc refuseRoot() =
  ## 3code runs arbitrary shell commands the model proposes — root
  ## blast radius is unacceptable. The install script also refuses, so
  ## a normal `curl | sh` user shouldn't ever see this; it's the safety
  ## net for `sudo 3code`, root containers, etc.
  when defined(posix):
    if geteuid() == 0 and getEnv("THREECODE_ALLOW_ROOT").len == 0:
      stderr.writeLine "3code: refusing to run as root. " &
        "Run as your normal user. (override: THREECODE_ALLOW_ROOT=1)"
      quit ExitUsage

proc ensureBash() =
  ## Windows startup guard: 3code depends on bash, and the supported source
  ## is the MSYS2 tree the installer drops into the 3code app dir
  ## (`%LOCALAPPDATA%\3code\msys64`). Hard-fail if it is missing — the one
  ## fix is to (re)run the installer, which also bootstraps MSYS2. POSIX
  ## always has /bin/sh so this is a no-op there.
  ##
  ## The provider-stub binary (the tty test harness) skips this: those tests
  ## drive REPL rendering, not bash enforcement, and CI has no bundled MSYS2
  ## so the guard would hard-fail before the prompt appears. Bash enforcement
  ## is covered by the cli_args `sandbox` suite and by production. Same gate as
  ## initSandbox.
  when defined(windows) and not defined(providerStub):
    let b = resolveBash()
    if b.len == 0:
      stderr.writeLine "3code: bash not found. Re-run the installer to set it up:"
      stderr.writeLine "  irm https://3code.capocasa.dev/install.ps1 | iex"
      quit ExitUsage

proc initSandbox(cwd: string) =
  ## Load the sandbox policy into the global state and resolve this
  ## binary's own path for bash wrapping. Exactly one file is active:
  ## the repo `.sandbox` when it exists, else the user file
  ## `~/.config/3code/sandbox` when the user wrote one, else the
  ## built-in default in memory, so the sandbox is always on without
  ## 3code ever creating the user file. When `sandboxEnabled` is false
  ## (the `[settings] sandbox = off` switch), this does nothing: bash
  ## runs unconfined and the in-process checks pass through (`active`
  ## stays false).
  # The provider stub binary (the tty/visual test harness) skips sandbox
  # setup entirely so its behaviour matches the pre-sandbox binary. Those
  # tests drive REPL rendering, not enforcement, and `active=true` plus the
  # startup probe shift the wall-clock timing the spinner/SIGWINCH
  # assertions depend on. Enforcement is covered by the cli_args `box`
  # suite and by production.
  when defined(providerStub):
    return
  if not sandboxEnabled:
    return
  sandbox.hiddenRules = sandbox.guardRules(cwd)
  sandbox.current = sandbox.loadPolicy(cwd)
  sandbox.active = true
  # The bash tool re-execs this binary as `3code sandbox restrict ...`, so
  # resolve our own path once. The sandbox subcommand is always compiled in, but
  # the OS-native restriction can still be nonfunctional (a kernel without
  # Landlock, a CI runner under a seccomp filter that blocks the syscall).
  # On failure, clear procboxExe so the bash tool degrades to the unconfined
  # setsid path instead of failing every command. The in-process
  # read/write/patch checks stay in force via `active` regardless. The
  # probe runs silently; the backend being unavailable is a host limitation,
  # not an error the user can act on.
  sandbox.procboxExe = sandbox.findProcbox()
  if not sandbox.backendWorks(sandbox.procboxExe):
    sandbox.procboxExe = ""

proc setupTlsEnv() =
  ## macOS: stock LibreSSL at `/usr/lib/libssl.dylib` fails handshakes
  ## against most modern endpoints, so we ship Homebrew OpenSSL 3 dylibs
  ## alongside the binary (see `release.yml`). Prepend the binary's
  ## directory to DYLD_LIBRARY_PATH so `dlopen("libssl.dylib")` (from
  ## Nim's std/net openssl wrapper) hits ours first. dyld consults the
  ## env var on every dlopen, so updating it from inside the process
  ## before any TLS code runs is sufficient.
  ##
  ## Windows: DLLs are found next to the .exe by the app-directory
  ## rule, no path manipulation needed.
  ##
  ## CA bundle: bundled OpenSSL on both platforms has its OPENSSLDIR
  ## baked to a build-runner path that doesn't exist on user systems,
  ## so verifyMode=CVerifyPeer can't scan default locations. Code that
  ## opens a TLS context calls `bundledCaFile()` (in util.nim) to feed
  ## the bundled `cacert.pem` directly to `newContext(caFile = ...)`.
  ## Linux uses the system trust store and needs nothing here.
  ## Termux's openssl libs are found via DT_RUNPATH baked in at link
  ## time (see config.nims); LD_LIBRARY_PATH can't help because the
  ## openssl wrapper dlopens at module init, before main runs.
  when defined(macosx):
    let dir = parentDir(getAppFilename())
    let cur = getEnv("DYLD_LIBRARY_PATH")
    let newVal = if cur.len > 0: dir & ":" & cur else: dir
    putEnv("DYLD_LIBRARY_PATH", newVal)

const NotifyMinSeconds = 5.0

proc notifyTurnFinished(messages: JsonNode) =
  let last = messages[^1]
  if last.kind != JObject or last{"role"}.getStr != "assistant": return
  let body = last{"content"}.getStr
  if body.len == 0: return
  notify("3code", "Turn finished", body)

proc commitUserPromptTranscript(line: string) =
  ## Controller-owned transcript append for user prompt items submitted
  ## mid-turn (the queued-prompt path). Delegates to emitUserSubmit so both
  ## the normal and queued submit paths share one separator/spacing model.
  emitUserSubmit(line)

proc cleanup() {.noconv.} =
  ## Single point of process teardown. Restores terminal state and
  ## releases the session lock. Registered as the only exit proc and called
  ## directly from signal handlers and the REPL's quit paths, so every way
  ## out (Ctrl-C, Ctrl-D, :q, SIGTERM, SIGHUP, uncaught exception) runs the
  ## same restore sequence.
  ##
  ## Idempotent: each step is guarded against double-invocation so an exit
  ## proc firing after a signal handler (or vice versa) does no harm.
  ##
  ## The persistent input thread is deliberately NOT joined here: it owns
  ## closures whose ORC cycle-collection crosses threads and segfaults if
  ## the thread returns while the editor is still live. We restore its
  ## termios snapshot directly instead; `exit()` kills the thread without
  ## running its epilogue, avoiding the cross-thread teardown.
  fatprompt.restoreInputTermios()
  minline.restoreTerminal()
  restoreCancelTermios()
  when defined(posix):
    sandbox.stopWall()
  # Final best-effort save of the prompt draft so a kill/power-off/SIGTERM
  # never loses a half-typed prompt. flushDraftNow uses tryAcquire inside so it
  # is safe to call from a signal handler on any thread. The flusher thread is
  # only signaled to stop (never joined): a signal can be delivered to the
  # flusher thread itself, and joining oneself would deadlock. exit() tears it
  # down like the other background threads.
  fatprompt.stopDraftFlusher()
  fatprompt.flushDraftNow()
  releaseActiveSessionLock()
  releaseActiveDirLock()

# Unhandled exceptions (including Defects like AssertionDefect) go through
# reportUnhandledError then rawQuit, which skips exit procs. Restore the
# terminal here so a crash never leaves stdin in raw mode. Full cleanup is
# too raise-heavy for this hook; termios restore is the part the user feels.
unhandledExceptionHook = proc(e: ref Exception) {.nimcall, gcsafe, raises: [], tags: [].} =
  {.cast(raises: []), cast(tags: []).}:
    fatprompt.restoreInputTermios()
    minline.restoreTerminal()
    restoreCancelTermios()

proc main() =
  startupTrace("main-enter")
  # `sandbox` is the built-in sandwall CLI: the bash tool re-execs this
  # binary as `3code sandbox restrict ...`. Dispatch before any other
  # startup so the sandboxed command isn't weighed down by 3code's
  # TLS/config/session init and so refuseRoot etc. don't run inside the
  # confined child. `box` stays as a hidden alias for binaries already
  # running under the old name.
  let rawParams = commandLineParams()
  # All the early-dispatch subcommands below run with redirected or
  # piped stdio (box children, the stdio relay, elevated setup); their
  # exit procs must not splice terminal-restore escapes into the stream.
  if rawParams.len > 0 and rawParams[0] in
      ["sandbox", "sb", "box", "wall", "stdio-relay", "setup", "unsetup"]:
    minline.terminalRestoreSuppressed = true
  if rawParams.len > 0 and rawParams[0] in ["sandbox", "sb", "box"]:
    quit(boxMain(rawParams[1 .. ^1]))
  # `wall` is the network half of sandwall, same early-dispatch
  # rationale: proxy/connect children skip all of 3code's startup.
  # Internal: the user-facing names are `3code setup` / `3code unsetup`.
  if rawParams.len > 0 and rawParams[0] == "wall":
    quit(wallMain(rawParams[1 .. ^1]))
  # The CPLW stdio relay hop: sandwall's Windows backend prefixes the
  # sandboxed command with `<self> stdio-relay --`. Must dispatch before
  # anything interactive or the relay child would hang in the TUI.
  # wallMain accepts the arg shape `stdio-relay -- CMD ...` directly.
  when defined(windows):
    if rawParams.len > 0 and rawParams[0] == "stdio-relay":
      quit(wallMain(rawParams))
  # One-time elevated sandbox setup / teardown (see wall.nim). The
  # commands exist on every platform; POSIX reports "Windows only".
  if rawParams.len > 0 and rawParams[0] == "setup":
    quit(setupMain(rawParams[1 .. ^1]))
  if rawParams.len > 0 and rawParams[0] == "unsetup":
    quit(unsetupMain(rawParams[1 .. ^1]))
  # -v/-h must not pay for TLS env, stale-binary walk, or sandbox
  # sweep. On Windows a debug 3code.exe is tens of MB and those
  # walks dominate `--version`.
  for a in rawParams:
    if a in ["-v", "--version"]: echo Version; return
    if a in ["-h", "--help"]: usage()

  startupTrace("early-dispatch-done")
  setupTlsEnv()
  startupTrace("setupTlsEnv")
  cleanupStaleBinaries()
  startupTrace("cleanupStaleBinaries")
  when defined(posix):
    sandbox.sweepStaleWallDirs()
  refuseRoot()
  # Internal flag for the detached background worker. Run silently and
  # exit before any other startup work (skill extraction, config load).
  let cl = commandLineParams()
  if cl.len == 1 and cl[0] == "--self-update-check":
    selfUpdateCheck()
    return

  # ── CLI parse: run before any dependency checks so -h / -v / --list
  #    work on Windows even when bash is not installed yet ──
  var model = ""
  var args: seq[string]
  var pending = ""  # flag awaiting a space-separated value
  var resume = false
  var resumeId = ""
  var sessionOut = ""
  var listSessions = false
  var interactive = false
  var p = initOptParser(commandLineParams())
  for kind, k, v in p.getopt():
    case kind
    of cmdShortOption, cmdLongOption:
      case k
      of "v", "version": echo Version; return
      of "h", "help": usage()
      of "g", "good": printKnownGood(); return
      of "x", "experimental": experimentalEnabled = true
      of "no-sandbox": sandboxEnabled = false
      of "D", "debug": debugEnabled = true
      of "i", "interactive": interactive = true
      of "m", "model":
        if v != "": model = v
        else: pending = "model"
      of "s", "session":
        if v != "": sessionOut = v
        else: pending = "session"
      of "r", "resume":
        resume = true
        if v != "": resumeId = v
      of "l", "list":
        # Short flags accumulate, so `-la` / `-al` both set this true
        # (parseopt emits one cmdShortOption per clustered letter).
        # Listing is directory-scoped by design; the full set lives
        # under `sessionDir()`.
        listSessions = true
      of "a", "all":
        # Reserved for a future all-directories listing; for now it's a
        # recognized no-op that still implies `-l` so `-la` stacks. To
        # re-enable: set a `listAllDirs` flag here and thread it into
        # the listing call below as `showCwd = true`.
        listSessions = true
      else: die("unknown option: -" & (if k.len == 1: "" else: "-") & k, ExitUsage)
    of cmdArgument:
      if pending == "model":
        model = k
        pending = ""
      elif pending == "session":
        sessionOut = k
        pending = ""
      else:
        args.add k
    of cmdEnd: discard
  if pending != "":
    die("option --" & pending & " requires a value", ExitUsage)

  # Apply a provisional palette before any colored output (update notices,
  # onboarding). The mode can only be forced to dark/light here; full
  # detection runs after the config file is read so `[settings] mode` can
  # pin a palette, then `[colors]` overrides are layered on top.
  applyPalette(cmDark)

  if listSessions:
    let paths = listSessionPathsForCwd(safeCwd())
    if paths.len == 0:
      stderr.writeLine "3code: no saved sessions for " & safeCwd()
      quit ExitConfig
    printSessionList(paths, "", showCwd = false)
    return

  if args.len > 0:
    case args[0]
    of "good": printKnownGood(); return
    else: discard

  # Validate --resume targets before side-effecting startup work so a
  # bogus id fails fast (no skill extraction, no lock) the same way a
  # usage error does. A prompt alongside --resume is now legitimate
  # (run it once resumed), so only the id is checked here.
  if resume:
    if resolveSessionPath(resumeId, safeCwd()) == "":
      if resumeId == "":
        die("no saved sessions for " & safeCwd(), ExitConfig)
      else:
        die("session not found: " & resumeId, ExitConfig)

  # ── All syntax validation and fast-exit dispatches are done; only now
  #    do we gate on bash (Windows) and run the side-effecting startup work
  #    (global interrupt hook, skill extraction disk I/O, background
  #    auto-update fork). A usage error must bail before any of it, and a
  #    session load must not pay for it twice. ──
  startupTrace("cli-parse-done")
  ensureBash()
  startupTrace("ensureBash")
  installInterruptHook()
  startupTrace("installInterruptHook")
  materializeBuiltinSkills()
  startupTrace("materializeBuiltinSkills")
  showUpdateNoticeMaybe()
  startupTrace("showUpdateNoticeMaybe")
  spawnBackgroundUpdateMaybe()
  startupTrace("spawnBackgroundUpdateMaybe")

  let prompt = args.join(" ")
  var session: Session
  var messages: JsonNode
  var restoredDraft = ""

  if resume:
    # `resolveSessionPath` already ran (and bailed) above; recompute the
    # resolved path here without re-validating, since nothing between the two
    # points can change the on-disk set.
    (session, messages) = loadSessionFile(resolveSessionPath(resumeId, safeCwd()))
    # Recover any prompt that was in-flight when the previous process ended
    # (kill, power-off, Ctrl-C). Only restored when no explicit --prompt was
    # passed: the user's command-line intent wins over the recovered draft.
    if prompt == "":
      restoredDraft = loadDraft(session.savePath)
  else:
    messages = %* [{"role": "system", "content": DefaultSystemPrompt}]
    session.created = $now()
    session.cwd = safeCwd()
    session.savePath = if sessionOut != "": sessionOut else: newSessionPath()
    # Recover a prompt drafted by a previous run in this directory that was
    # killed before its first turn (so no `.3log` / session draft exists for
    # it). It was saved under a cwd-keyed pending path; restore it here so the
    # next fresh session picks it up. Skipped when an explicit --prompt was
    # passed — the user's command-line intent wins over the recovered draft.
    if prompt == "":
      restoredDraft = loadPendingDraft(session.cwd)

  # Sandbox is mandatory: the single active policy (repo
  # `.sandbox`, user file, else the built-in default) is loaded.
  # Paths resolve relative to the session cwd so the policy follows
  # the project, not the binary.
  initSandbox(session.cwd)
  startupTrace("initSandbox")
  # Windows: when the dedicated sandbox user / creds are not set up,
  # initSandbox clears procboxExe and every bash tool call runs
  # unconfined (host rules unfenced). Say so once at startup, where the
  # user sees it before trusting the sandbox, instead of only inside the
  # first bash turn. Cheap: backendWorks on Windows is a user+creds
  # check, no WFP engine open, no spawn.
  when defined(windows) and not defined(providerStub):
    if sandboxEnabled and sandbox.active and sandboxWallWarn and
        sandbox.procboxExe.len == 0:
      stderr.writeLine("3code: Windows sandbox is not set up; bash " &
        "runs unconfined and policy host rules are NOT enforced. " &
        "Run `3code setup` once as admin. " &
        "(disable this warning: [settings] sandbox_wall_warn = off)")
    startupTrace("sandbox-setup-warn")

  try:
    acquireDirLock(session.cwd)
  except DirLocked as e:
    die(e.msg, ExitConfig)

  try:
    acquireSessionLock(session.savePath)
  except SessionLocked as e:
    releaseDirLock(session.cwd)
    die(e.msg, ExitConfig)

  # Subscription auth: oauth-marked providers resolve their bearer
  # through the token store (auto-refresh) instead of a static key.
  # ChatGPT additionally needs its Codex-backend headers on every call.
  subscriptionTokenForImpl = proc(provider: string): string {.closure.} =
    result = auth_xai.subscriptionTokenFor(provider)
    if result == "":
      result = auth_openai.subscriptionTokenFor(provider)
  extraHeadersImpl = chatgptExtraHeaders
  api.codexModelsHook = auth_openai.fetchCodexModels
  api.bearerHook = subscriptionBearer
  api.extraHeadersHook = extraHeadersFor

  var activeColorKeys: Table[string, string]
  (activeCurrent, activeProviders, activeColorKeys) = loadStateOrEmpty(configPath())
  if activeProviders.len == 0 and activeCurrent != "":
    # A config that sets `current` but has no [provider] section used to
    # fall through to the first-run wizard, which then refused every name
    # with "already configured" (the wizard's ledger check reads the same
    # `current`). Diagnose the config instead of pretending it's a first
    # run.
    die(configPath() & ": no [provider] section; add one or remove " &
        "'current' from [settings]", ExitConfig)
  # Resolve the real mode now that `[settings] mode` has been read: detect
  # the terminal background unless the config pinned a palette. The palette
  # is re-applied so the welcome screen (rendered next) uses the resolved
  # colors before `[colors]` overrides are layered on top.
  startupTrace("locks-acquired")
  applyPalette(detectColorMode(colorModePref))
  startupTrace("palette-detect")
  if activeColorKeys.len > 0:
    let (both, lightOnly) = splitColorOverrides(activeColorKeys)
    applyColorOverrides(both, lightOnly)
  let wantedProfile =
    if model != "": model
    elif resume and session.profileName != "": session.profileName
    else: ""
  var prof = resolveSessionProfile(wantedProfile, session.profileName)
  var editor = welcome(prof)
  startupTrace("welcome")
  # Terminal, session lock, and thread cleanup all funnel through a single
  # exit proc so every exit path restores the same state. SIGTERM/SIGHUP get
  # their own handler because the default disposition skips exit procs.
  addExitProc(cleanup)
  when defined(posix):
    proc signalCleanup(sig: cint) {.noconv.} =
      cleanup()
      signal(sig, SIG_DFL)
      discard posix.raise(sig)
    signal(SIGTERM, signalCleanup)
    signal(SIGHUP, signalCleanup)
  editor.completionCallback = proc(ed: minline.LineEditor): seq[string] =
    completionFor(ed.lineText)
  # The bootstrap provider wizard (and every later prompt) reads via the
  # input thread, whose startup guard is `inputEditor != nil`. Wire the
  # module-global pointers before the wizard can run, or the first-run
  # wizard raises `IOError("input thread stopped")` at its first prompt.
  inputEditor = addr(editor)
  inputMessages = addr(messages)
  inputSession = addr(session)
  inputProfile = addr(prof)
  # The wizard's verification pool cancels via stdin polling on the main
  # thread while the input thread is parked between wizard prompts.
  wizardVerifyCancelHook = installWizardVerifyCancel
  if prof.name == "":
    prof = bootstrapProvider(editor)
  session.profileName = prof.name
  setActiveCommandHook(proc(cmd: string) {.gcsafe.} =
    {.cast(gcsafe).}:
      let kind = classifyCommand(cmd)
      case kind
      of ckSafeImmediate:
        if inputMessages == nil or inputSession == nil or inputProfile == nil or
            inputEditor == nil:
          return
        var res = handleCommandResult(cmd, inputMessages[], inputSession[],
                                      inputProfile[], inputEditor[])
        if not res.recognized:
          res = CommandResult(recognized: true, ok: false, name: "command",
                              body: "unknown command: " & cmd.strip &
                                    "  (try :help)\n")
        let bytes = plainCommandBodyBytes(res.body)
        commitTranscriptBytes(bytes, restoreEditor = true, reserveFooter = true)
      of ckQuit:
        pushInputEvent(InputEvent(kind: ieQuit))
        requestTurnInterrupt("quit-command-during-turn")
      of ckMutating, ckModal:
        let msg = "cannot run " & cmd.strip & " while a turn is active"
        let bytes = plainCommandBodyBytes(msg & "\n")
        commitTranscriptBytes(bytes, restoreEditor = true, reserveFooter = true)
      else:
        let bytes = plainCommandBodyBytes(
          "unknown command: " & cmd.strip & "  (try :help)\n")
        commitTranscriptBytes(bytes, restoreEditor = true, reserveFooter = true)
  )

  proc handleBufferedAfterTurn(): bool =
    var queued = ""
    var queuedRows = 0
    while true:
      let ev = pollInputEvent()
      case ev.kind
      of ieQuit:
        return true
      of ieLine:
        if queued.len == 0:
          queued = ev.text
          queuedRows = ev.echoRows
        # drain any remaining events; keep first line only
      of ieCommand:
        discard  # commands handled by activeCommandHook during turn
      of ieInterrupt:
        discard  # already handled
      of ieNone:
        break
    if queued.len == 0:
      return false
    if prof.name == "":
      editor.prefillText = queued
      return false
    messages.add %*{"role": "user",
                    "content": buildUserMessage(messages, queued)}
    refreshSystemPrompt(messages, prof)
    editor.echoRows = queuedRows
    commitUserPromptTranscript(queued)
    resetEditorRowModel(addr editor)
    editor.prefillText = ""
    clearDraft(session)
    discard runTurnsInteractive(prof, messages, session)
    handleBufferedAfterTurn()

  # Run one turn + its post-turn cleanup under a single safety net.
  # `runTurnsInteractive` catches ApiError/OSError/IOError/CatchableError
  # inside the turn body, but the cleanup that follows it
  # (`notifyTurnFinished`, `handleBufferedAfterTurn`, the editor redraw)
  # writes to stdout and can raise IOError if the terminal/pipe is
  # already gone. Without this outer catch the IOError escapes main
  # and the process dies silently. We surface it on stderr and quit
  # cleanly so the user isn't left staring at a dead prompt.
  # In debug builds (`nim c`, no `-d:release`) we re-raise so the
  # developer sees the full Nim stack via the unhandled-exception
  # printer instead of the sanitized one-liner.
  proc runTurnWithSafetyNet(): bool =
    let turnStart = epochTime()
    try:
      let interrupted = runTurnsInteractive(prof, messages, session)
      if not interrupted and notifyEnabled and
          epochTime() - turnStart >= NotifyMinSeconds:
        notifyTurnFinished(messages)
      result = handleBufferedAfterTurn()
    except IOError as e:
      stderr.writeLine "3code: output stream broken (" & e.msg &
        "); session saved. If you ran 3code from a pipe or a now-closed " &
        "terminal, reattach before sending more prompts."
      result = true   # treat as quit so the REPL loop exits cleanly
    except CatchableError as e:
      when not defined(release):
        raise
      let trace = e.getStackTrace()
      stderr.writeLine "3code: internal error during turn: " & e.msg
      if trace.len > 0:
        stderr.writeLine trace
      stderr.writeLine "3code: session saved at " & session.savePath &
        ". Please open an issue with the lines above."
      result = true

  # Run a prompt that arrived on the command line (or was queued during
  # startup) through the exact same sequence as a typed submit in the
  # REPL loop below: append the message, refresh the system prompt, do
  # the user-submit transition (receipt repaint + prompt echo), reset the
  # editor, clear the draft, run the turn, and fire the turn-finished
  # notification under the same condition as a typed turn. Returns true
  # if a buffered quit/interrupt event should end the session.
  proc runInitialPrompt(text: string): bool =
    messages.add %*{"role": "user", "content": buildUserMessage(messages, text)}
    refreshSystemPrompt(messages, prof)
    emitUserSubmit(text)
    resetEditorRowModel(addr editor)
    clearDraft(session)
    result = runTurnWithSafetyNet()

  try:
    # Draw the initial chrome at the bottom of the welcome screen. On
    # resume with prior usage we paint bar+prompt carrying the last
    # response's tokens (typing-ready shape from `endTurn`). On resume
    # without usage and on a fresh start we paint a bare idle prompt;
    # the token bar first appears when a turn ends with real usage.
    if restoredDraft.len > 0:
      editor.prefillText = restoredDraft
    if resume:
      stdout.write "\n"
      stdout.styledWriteLine styleDim, &"● resumed {sessionIdFromPath(session.savePath)}", resetStyle
      let window = contextWindowFor(prof)
      let lastUsage = replaySessionTail(messages, session.toolLog,
                                        window, prof.family)
      if lastUsage.totalTokens > 0:
        # Same shape as `endTurn`: gap row + bar+prompt in typing-ready
        # state, carrying the last response's usage so
        # the bar replaces what would otherwise be the last receipt.
        # `pendingHint` is primed so the next user submit converts this
        # bar into the receipt for that response. Painted through the
        # fat-prompt runtime so the chrome's height is registered in the
        # engine: a raw paint leaves `paintedFooterRows` at 0, and every
        # keystroke repaint then under-walks and stacks a duplicate
        # gap+bar pair per keypress.
        stdout.write "\n"
        let label = tokenLineLabel(lastUsage, window)
        emitFatPromptEvent setBarEvent(label, hasGap = true)
        emitFatPromptEvent setPendingHintEvent(lastUsage, window, -1)
        paintResumedBarPrompt(label)
      else:
        paintInitialPrompt(prof)
    else:
      paintInitialPrompt(prof)
    # The startup paint is a render boundary the tty harness synchronizes
    # on: without the frame event the first captured frame can predate the
    # chrome (or miss it entirely when the PTY burst is coalesced).
    emitTestFrameEvent()
    startupTrace("first-prompt-painted")
    if prompt != "" and runInitialPrompt(prompt):
      # quit, not return: unwinding `editor` while the input thread still
      # holds it is the Windows oneshot SIGSEGV (illegal storage access).
      quit(0)
    # Oneshot: a prompt given on the command line runs once and exits. Only
    # -i/--interactive keeps the REPL open afterward (and no prompt at all
    # means a fresh interactive session). The idle prompt painted by endTurn
    # is transient chrome; clear it so the process ends on the last reply
    # line rather than a dangling caret.
    if prompt != "" and not interactive:
      emitFatPromptEvent clearPendingHintEvent()
      emitFatPromptEvent clearBarEvent()
      termengine.renderFooter(clearFooterFrame(), inputThreadRunning,
                              addr editor)
      quit(0)
    while true:
      var done = false
      var line = readInput(editor, done)
      if done:
        echo ""
        break
      if line == "": continue
      let t = line.strip
      if t in ["exit", "quit", ":q", ":quit", ":exit"]: break
      let commandResult = handleCommandResult(line, messages, session, prof, editor)
      if commandResult.recognized:
        if commandResult.disposition == cdModal:
          # The modal wizard runs on the input thread via
          # `wizardReadLine` (see `src/threecode/fatprompt/runtime.nim`).
          # The wizard keeps `inputModalActive` held across successful
          # submits so the persistent prompt cannot race the wizard's
          # post-processing (verify round-trip, ledger write, status
          # lines). Releasing the hold here, after `handleCommandResult`
          # returns, lets the input thread repaint the persistent prompt
          # on the row directly below whatever the wizard's caller wrote
          # — instead of overlapping `❯ ` with `verifying... ok`.
          wizardFinish()
          # The wizard's status lines (`added <name>`, the resulting
          # profile) are ordinary transcript items, committed through the
          # same single history path as every other command result.
          if commandResult.body.len > 0:
            commitTranscriptBytes(
              plainCommandBodyBytes(commandResult.body),
              restoreEditor = true,
              reserveFooter = true)
          continue
        # This path bundles two distinct items (prompt echo + command
        # output) into a single transcript commit. `appendTranscript`
        # prepends exactly one separator before the whole blob; the blank
        # between the echo and the command output must be inserted here.
        let echoBytes = formatItem(userPromptItem(line))
        let commandBytes = plainCommandBodyBytes(commandResult.body)
        let bytes = echoBytes & "\r\n\r\n" & commandBytes
        proc clearSubmittedCommandEditor() =
          resetEditorRowModel(addr editor)
          if commandResult.clearFooter:
            emitFatPromptEvent clearPendingHintEvent()
            emitFatPromptEvent clearBarEvent()
        commitTranscriptBytes(
          bytes,
          restoreEditor = true,
          beforeRepaint = clearSubmittedCommandEditor,
          reserveFooter = true)
        releaseIdleSubmittedInput()
        continue
      if prof.name == "":
        commitTranscriptBytes(
          errLnS("no provider configured. use :provider add"), true)
        releaseIdleSubmittedInput()
        continue
      messages.add %*{"role": "user", "content": buildUserMessage(messages, line)}
      refreshSystemPrompt(messages, prof)
      # User-submit transition: walk back to the previous turn's bar
      # row, repaint it as the receipt (cyan, skipped on the first turn),
      # echo the user's input as scroll-history content. Cursor lands
      # on the row directly after the last echo line, where callModel's
      # leading `\n` will set up the new spinner-footer scratch row.
      emitUserSubmit(line)
      resetEditorRowModel(addr editor)
      # The prompt is now a committed user turn: drop the draft sidecar so a
      # clean exit doesn't restore text the user already sent.
      clearDraft(session)
      if runTurnWithSafetyNet(): break

  except IOError as e:
    stderr.writeLine "3code: output stream broken (" & e.msg &
      "); session saved."
    quit(0)
  except CatchableError as e:
    when not defined(release):
      raise
    let trace = e.getStackTrace()
    stderr.writeLine "3code: internal error: " & e.msg
    if trace.len > 0:
      stderr.writeLine trace
    stderr.writeLine "3code: session saved at " & session.savePath &
      ". Please open an issue with the lines above."
    quit(1)
when isMainModule:
  main()
