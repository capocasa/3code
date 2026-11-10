#[ Headless entry points: `--headless` and `--gui`.
##
## `--headless` runs the agent with zero output — no TUI, no banner, no
## tool lines, no stderr on failure; the exit code is the whole report
## (0 ok, 1 turn failed or interrupted, 2 usage, 3 config). The point
## is embedding: scripts and native GUIs want the work, not the paint.
## Everything runs through the library's AgentSession (the internal
## API), whose headless plumbing already silences the engine output.
##
## `--gui` is headless plus a plugin frontend: the process stays alive,
## every plugin exporting `tc_frontend` gets its own thread to run a
## GUI on (in-process), and the plugin drives the agent back through
## the `agent*` services (see pluginagent.nim). When every frontend
## returns, the process ends.
##
## Both dispatch before any terminal setup, like `--acp`/`--rpc`; the
## main entry point calls here AFTER plugins have loaded (a `--gui`
## run needs the frontend registered, and `[plugins]` gating must be
## read first).
]##

import std/[json, os, parseopt, strutils]
import types, util, config, api, library, plugins, pluginagent, minline
import dirsettings

type HeadlessOpts = object
  gui: bool
  model: string
  resumeId: string
  resume: bool
  sessionOut: string
  experimental: bool
  debug: bool
  privateRun: bool
  noSandbox: bool
  prompt: string

proc parseHeadless(args: seq[string]): HeadlessOpts =
  var o = HeadlessOpts()
  if args.len == 0: return o
  o.gui = args[0] == "--gui"
  var rest = args[1 .. ^1]
  var pending = ""  # flag awaiting a space-separated value
  var words: seq[string]
  # An empty cmdline would make parseopt parse the REAL argv instead
  # (initOptParser's documented fallback), so the loop only runs when
  # there is something after the --headless/--gui token.
  if rest.len > 0:
    var p = initOptParser(rest, shortNoVal = {'x', 'p', 'D'},
                          longNoVal = @["experimental", "private", "debug",
                                        "no-sandbox"])
    for kind, k, v in p.getopt():
      case kind
      of cmdLongOption, cmdShortOption:
        case k
        of "m", "model":
          if v != "": o.model = v
          else: pending = "model"
        of "c", "config":
          if v != "": configPathOverride = v
          else: pending = "config"
        of "r", "resume":
          o.resume = true
          if v != "": o.resumeId = v
          else: pending = "resume"
        of "s", "session":
          if v != "": o.sessionOut = v
          else: pending = "session"
        of "x", "experimental": o.experimental = true
        of "p", "private": o.privateRun = true
        of "D", "debug": o.debug = true
        of "no-sandbox": o.noSandbox = true
        else: quit(ExitUsage)
      of cmdArgument:
        case pending
        of "model": o.model = k; pending = ""
        of "config": configPathOverride = k; pending = ""
        of "session": o.sessionOut = k; pending = ""
        of "resume": o.resumeId = k; pending = ""
        else: words.add k
      of cmdEnd: discard
  # bare `-r` means "resume the latest session for this directory"
  if pending notin ["", "resume"]: quit(ExitUsage)
  o.prompt = words.join(" ")
  o

proc headlessMain*(args: seq[string]): int =
  ## `3code --headless [flags] [prompt words...]` and
  ## `3code --gui [flags]`: returns the process exit code. Prints
  ## nothing on any path (headlessMode gates `die`); failures are exit
  ## codes, and turn failures additionally surface as agent error
  ## events for a `--gui` frontend.
  types.headlessMode = true
  minline.terminalRestoreSuppressed = true
  let o = parseHeadless(args)
  experimentalEnabled = o.experimental
  privateMode = o.privateRun
  debugEnabled = o.debug
  if o.noSandbox: sandboxEnabled = false
  installInterruptHook()

  if o.gui:
    # The agent services must answer before any frontend thread asks.
    installPluginAgentServices()
    if pluginFrontendCount() == 0:
      die("no plugin provides a GUI (drop one exporting tc_frontend in " &
          userDataRoot() / "lib" & ")", ExitConfig)
    var argv = newJArray()
    for a in commandLineParams(): argv.add %a
    discard pluginsFrontendRun(safeCwd(), $argv)
    # A GUI that quit without agentClose still gets its session saved
    # and its locks released; a no-op when nothing was opened.
    discard pluginagent.agentForceClose()
    pluginsShutdown()
    return 0

  if o.prompt == "" and not o.resume:
    # Nothing to do is a usage error, not a silent no-op exit.
    quit(ExitUsage)
  var s: AgentSession
  try:
    s = initAgentSession(AgentOptions(
      model: o.model,
      resumeId: o.resumeId,
      resume: o.resume,
      sessionPath: o.sessionOut,
      experimental: o.experimental,
      debug: o.debug))
  except AgentError:
    return ExitConfig
  try:
    discard s.prompt(o.prompt)
  except AgentError:
    s.close()
    return 1
  s.close()
  0
