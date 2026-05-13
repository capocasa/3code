## Functional test harness.
##
## Provides a fake TTY environment so tests can exercise real code paths
## (inputThreadProc, beginTurn/endTurn, readLineWith) against a ttty grid
## instead of a real terminal.
##
## Architecture:
##
##   test code ──write keystrokes──> PTY master
##                                     PTY slave ──> stdin
##
##   stdout ──> pipe ──read bytes──> ttty grid  (assertions)
##
## The PTY slave replaces stdin so tcGetAttr/tcSetAttr (raw mode),
## poll(STDIN_FILENO), and stdin.readChar() all work as in production.
## A pipe replaces stdout so all output is captured and fed to a ttty
## grid for cell-level assertions.
##
## Usage:
##
##   var ft = newFakeTerm()   # redirect stdin+stdout
##   defer: ft.close()        # restore and cleanup
##
##   # ... call production code that writes to stdout ...
##
##   ft.drain()               # restore stdout, capture into grid
##   check "❯" in rowText(ft.grid, 1)
##
## The split between newFakeTerm (redirect) and drain (restore+capture)
## ensures that test assertions (which write to the real stdout) don't
## pollute the captured output.

import std/syncio
import ttty/grid
when defined(posix):
  import posix/termios
  import posix except Termios

when defined(posix):
  proc openpty(amaster, aslave: ptr cint, name: cstring,
               termp, winp: pointer): cint {.importc, header: "<pty.h>".}
  proc fileno(f: File): cint {.importc, header: "<stdio.h>".}

const
  SavedFdIn = 200
  SavedFdOut = 201

type
  FakeTerm* = ref object
    ptm*: cint
    grid*: Grid
    outReadFd*: cint
    origTermios*: Termios
    drained*: bool

proc newFakeTerm*(): FakeTerm =
  ## Create and install fake terminal. Stdin and stdout are redirected.
  ## Call `drain()` to restore stdout and capture output into the grid.
  ## Call `close()` to fully restore both and free fds.
  when defined(posix):
    var ptm, pts: cint
    doAssert openpty(addr ptm, addr pts, nil, nil, nil) == 0
    var outFds: array[2, cint]
    doAssert pipe(outFds) == 0

    result = FakeTerm(
      ptm: ptm,
      grid: newGrid(),
      outReadFd: outFds[0],
    )

    discard dup2(fileno(stdin), SavedFdIn)
    discard dup2(pts, fileno(stdin))
    discard close(pts)
    discard dup2(fileno(stdout), SavedFdOut)
    discard dup2(outFds[1], fileno(stdout))
    discard close(outFds[1])
    discard tcGetAttr(fileno(stdin), addr result.origTermios)

proc drain*(ft: FakeTerm) =
  ## Restore stdout to real terminal, then read all captured output
  ## from the pipe into the grid. Must be called before assertions
  ## (which need real stdout for test output). Can be called multiple
  ## times — each call captures output since the last drain.
  when defined(posix):
    stdout.flushFile()
    discard dup2(SavedFdOut, fileno(stdout))
    ft.drained = true
    var buf: array[4096, char]
    var wait = 50.cint
    while true:
      var pfd: Tpollfd
      pfd.fd = ft.outReadFd
      pfd.events = POLLIN
      let r = poll(addr pfd, 1.TNFDS, wait)
      if r <= 0: break
      let n = posix.read(ft.outReadFd, buf[0].addr, 4096)
      if n <= 0: break
      var s = newString(n)
      copyMem(s[0].addr, buf[0].addr, n)
      ft.grid.feed s
      wait = 0

proc feedKeys*(ft: FakeTerm, keys: string) =
  ## Write keystrokes to the PTY master (simulates user typing).
  when defined(posix):
    discard write(ft.ptm, keys[0].unsafeAddr, keys.len)

proc close*(ft: FakeTerm) =
  ## Restore original stdin/stdout and close all fake fds.
  when defined(posix):
    if ft.drained:
      discard tcSetAttr(SavedFdIn, TCSADRAIN, addr ft.origTermios)
    else:
      discard tcSetAttr(fileno(stdin), TCSADRAIN, addr ft.origTermios)
    discard dup2(SavedFdIn, fileno(stdin))
    if not ft.drained:
      discard dup2(SavedFdOut, fileno(stdout))
    discard close(ft.ptm)
    discard close(ft.outReadFd)
