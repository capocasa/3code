## Streaming bash execution using osproc.startProcess.
##
## Runs a shell command with stdout piped for line-by-line reading.
## Each complete stdout line is forwarded to the `onLine` callback for
## live display.  stderr is written to a temp file (read after exit).
## Returns raw output, raw stderr, and the exit code — clipping and
## post-processing live in `actions.nim`.

import std/[os, osproc, streams, strformat, strutils, tables, times]
import types, util, shell

proc localFileSig(path: string): (Time, int) =
  try: (getLastModificationTime(path), getFileSize(path).int)
  except CatchableError: (Time(), 0)

proc runStreamingBash*(act: Action, cache: ReadCache,
                       onLine: proc(line: string) = nil):
    tuple[rawOut: string, rawErr: string, code: int] =
  let cmd = act.body.strip
  let mutPath = bashMutationPath(cmd)
  let (readPath, fullRead) = bashReadPath(cmd)

  if cache != nil and mutPath != "" and mutPath != ".":
    let p = resolvePath(mutPath)
    if cache.state.hasKey(p) and fileExists(p):
      if localFileSig(p) != cache.state[p]:
        return (&"error: {p} changed on disk since the last read in this session — re-read before mutating", "", 1)

  if cache != nil and readPath != "" and fullRead:
    let p = resolvePath(readPath)
    if fileExists(p) and cache.state.hasKey(p) and localFileSig(p) == cache.state[p]:
      return (&"[unchanged since prior read of {p}; see earlier read in this session]", "", 0)

  let tmp = getTempDir() / ("3code_bash_" & $getCurrentProcessId() & "_" & $epochTime().int64)
  createDir(tmp)
  let errPath = tmp / "err"
  let scriptPath = tmp / "cmd.sh"
  let stdinPath = tmp / "stdin"

  let script = """export PAGER=cat GIT_PAGER=cat PSQL_PAGER=cat MYSQL_PAGER=cat
export LESS= TERM=dumb CI=1 NO_COLOR=1 GIT_TERMINAL_PROMPT=0
export DEBIAN_FRONTEND=noninteractive
""" & cmd & "\n"
  writeFile(scriptPath, script)
  writeFile(stdinPath, act.stdin)

  let wrapped = &"timeout --foreground 120s sh \"{scriptPath}\" <\"{stdinPath}\" 2>\"{errPath}\""

  var p = startProcess("/bin/sh", args = ["-c", wrapped],
                       options = {poStdErrToStdOut, poUsePath})

  var rawOut = ""
  let outStream = p.outputStream
  var lineBuf = ""
  while not outStream.atEnd:
    let ch = outStream.readChar()
    if ch == '\n':
      rawOut.add lineBuf & "\n"
      if onLine != nil:
        onLine(lineBuf)
      lineBuf.setLen(0)
    else:
      lineBuf.add ch

  if lineBuf.len > 0:
    rawOut.add lineBuf & "\n"
    if onLine != nil:
      onLine(lineBuf)

  let code = p.waitForExit()
  p.close()

  let rawErr = if fileExists(errPath): readFile(errPath) else: ""
  try: removeDir(tmp) except CatchableError: discard

  return (rawOut, rawErr, code)
