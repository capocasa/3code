## Non-interactive `3code provider` subcommand: the config half of the
## REPL's `:provider` wizard on the command line, for scripts and first
## setup without a TTY. Scope is provider management only — adding a
## provider, replacing its model list, removing it, listing what is
## configured. Switching the current model stays in the REPL (`:model`)
## and on `-m`; a CLI setter would grow a second sticky-current
## semantics for no benefit.
##
## Output is plain stdout (listings, confirmations) and stderr (errors),
## no ANSI styling: this runs in scripts and pipes. Exit codes follow
## the CLI convention (die: 1/2/3).
##
## `add` mirrors the wizard's resolution of the first field (catalog
## name, url, api key, subscription login) but takes the key and models
## from flags instead of prompts. Like the wizard's registry-trusted
## path, no verification ping runs: a bad key surfaces on the first
## turn. Subscription logins (chatgpt, claudecode, geminicli,
## supergrok) open the browser OAuth flow, which is the one
## interactive step; everything else is pipeable.

import std/[sequtils, strformat, strutils, tables]
import types, util, config, prompts, display, ui, providerops

proc providerUsage(): string =
  result.add "usage: 3code provider list\n"
  result.add "       3code provider add <name|url|api-key> [--key KEY] [--models \"a b c\"]\n"
  result.add "       3code provider models <name> <model...>\n"
  result.add "       3code provider rm <name>"

proc cliErr(msg: string) =
  stderr.writeLine "3code: " & msg

proc providerList() =
  if activeProviders.len == 0:
    echo "no providers configured"
    return
  let dot = activeCurrent.find('.')
  let curName = if dot < 0: activeCurrent else: activeCurrent[0 ..< dot]
  for pr in activeProviders:
    let mark = if pr.name == curName: "*" else: " "
    let plural = if pr.models.len == 1: "" else: "s"
    echo &"{mark} {pr.name}  {pr.models.len} model{plural}"

proc providerAdd(entry, keyFlag, modelsFlag: string) =
  if entry == "":
    cliErr "provider add: missing <name|url|api-key>"
    stderr.writeLine providerUsage()
    quit ExitUsage
  let (err, prov) = addProvider(entry, keyFlag, modelsFlag, oauthLoginFor)
  if err != "":
    cliErr err
    quit ExitConfig
  echo &"added {prov.name} ({prov.models.len} models) -> {configPath()}"

proc providerModels(name: string, models: seq[string]) =
  let err = setProviderModels(name, models)
  if err != "":
    cliErr err
    quit ExitConfig
  let n = activeProviders.filterIt(it.name == name)[0].models.len
  echo &"{name}: {n} models"

proc providerRm(name: string) =
  let err = removeProvider(name)
  if err != "":
    cliErr err
    quit ExitConfig
  echo &"removed {name}"

proc providerMain*(args: seq[string]): int =
  ## `3code provider ...` dispatch. Returns the exit code; callers
  ## `quit` with it. Config must already be loaded into
  ## `activeCurrent` / `activeProviders` (the CLI entry point does
  ## that before dispatching here).
  if args.len == 0 or args[0] in ["list", "ls"]:
    providerList()
    return 0
  case args[0]
  of "add":
    var entry = ""
    var keyFlag = ""
    var modelsFlag = ""
    var i = 1
    while i < args.len:
      case args[i]
      of "--key":
        if i + 1 >= args.len:
          cliErr "--key requires a value"
          return ExitUsage
        keyFlag = args[i + 1]; inc i
      of "--models":
        if i + 1 >= args.len:
          cliErr "--models requires a value"
          return ExitUsage
        modelsFlag = args[i + 1]; inc i
      else:
        if entry != "":
          cliErr "provider add: one entry only"
          return ExitUsage
        entry = args[i]
      inc i
    providerAdd(entry, keyFlag, modelsFlag)
  of "models":
    if args.len < 3:
      cliErr "provider models: need <name> and at least one model"
      stderr.writeLine providerUsage()
      return ExitUsage
    providerModels(args[1], args[2 .. ^1])
  of "rm", "remove":
    if args.len != 2:
      cliErr "provider rm: need exactly one name"
      stderr.writeLine providerUsage()
      return ExitUsage
    providerRm(args[1])
  else:
    cliErr "unknown subcommand: " & args[0]
    stderr.writeLine providerUsage()
    return ExitUsage
  0
