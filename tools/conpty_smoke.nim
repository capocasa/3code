## Standalone ConPTY smoke test, run DIRECTLY (not via testament) to isolate
## whether the 0xC0000142 failure is specific to the testament/git-bash console
## context or fundamental to the ConPTY sequence on this runner.
when not defined(windows):
  echo "windows-only"
  quit(0)

import std/[os, times]
import winlean

type
  HPCON = distinct Handle
  COORD = object
    x*, y*: int16
  SIZE_T = uint
  STARTUPINFOEX = object
    startupInfo*: STARTUPINFO
    lpAttributeList*: pointer

const
  PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = 0x00020016'u32
  EXTENDED_STARTUPINFO_PRESENT = 0x00080000'i32

proc createPseudoConsole(size: COORD; hInput, hOutput: Handle;
    dwFlags: uint32; phPC: ptr HPCON): int32 {.stdcall,
    dynlib: "kernel32", importc: "CreatePseudoConsole".}
proc closePseudoConsole(hPC: HPCON) {.stdcall,
    dynlib: "kernel32", importc: "ClosePseudoConsole".}
proc initializeProcThreadAttributeList(lpAttributeList: pointer;
    dwAttributeCount, dwFlags: DWORD; lpSize: ptr SIZE_T): WINBOOL {.stdcall,
    dynlib: "kernel32", importc: "InitializeProcThreadAttributeList".}
proc updateProcThreadAttribute(lpAttributeList: pointer; dwFlags: DWORD;
    attribute: uint; lpValue: pointer; cbSize: SIZE_T;
    lpPreviousValue: pointer; lpReturnSize: ptr SIZE_T): WINBOOL {.stdcall,
    dynlib: "kernel32", importc: "UpdateProcThreadAttribute".}
proc peekNamedPipe(hNamedPipe: Handle; lpBuffer: pointer; nBufferSize: DWORD;
    lpBytesRead, lpTotalBytesAvail, lpBytesLeftThisMessage: ptr int32): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "PeekNamedPipe".}
proc freeConsole(): WINBOOL {.stdcall, dynlib: "kernel32", importc: "FreeConsole".}
proc allocConsole(): WINBOOL {.stdcall, dynlib: "kernel32", importc: "AllocConsole".}
proc getConsoleWindow(): Handle {.stdcall, dynlib: "kernel32", importc: "GetConsoleWindow".}

proc main() =
  var sa = SECURITY_ATTRIBUTES(nLength: sizeof(SECURITY_ATTRIBUTES).int32,
                               bInheritHandle: 0)

  proc attempt(label: string; allocFirst, freeFirst: bool): bool =
    echo "--- attempt: ", label, " alloc=", allocFirst, " free=", freeFirst
    if freeFirst: discard freeConsole()
    if allocFirst: discard allocConsole()
    var inputRead, inputWrite, outputRead, outputWrite: Handle
    doAssert createPipe(inputRead, inputWrite, sa, 0) != 0
    doAssert createPipe(outputRead, outputWrite, sa, 0) != 0
    var hpc: HPCON
    let rc = createPseudoConsole(COORD(x: 80.int16, y: 30.int16),
                                 inputRead, outputWrite, 0, addr hpc)
    echo "  createPseudoConsole rc=", rc
    if rc != 0:
      discard closeHandle(inputRead); discard closeHandle(inputWrite)
      discard closeHandle(outputRead); discard closeHandle(outputWrite)
      return false
    var attrSize: SIZE_T = 0
    discard initializeProcThreadAttributeList(nil, 1, 0, addr attrSize)
    var attrList = cast[pointer](alloc0(attrSize))
    doAssert initializeProcThreadAttributeList(attrList, 1, 0, addr attrSize) != 0
    doAssert updateProcThreadAttribute(attrList, 0,
        PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE.uint, cast[pointer](unsafeAddr hpc),
        sizeof(HPCON).SIZE_T, nil, nil) != 0
    var si = STARTUPINFOEX(startupInfo: STARTUPINFO(cb: sizeof(STARTUPINFOEX).int32))
    si.lpAttributeList = attrList
    var pi: PROCESS_INFORMATION
    let cmd = getEnv("WINDIR") & "\\System32\\cmd.exe /c echo conpty_ok"
    let cmdW = newWideCString(cmd)
    let appW: WideCString = nil
    let ok = createProcessW(appW, cmdW, nil, nil, 0,
        EXTENDED_STARTUPINFO_PRESENT, nil, nil, si.startupInfo, pi)
    echo "  createProcessW ok=", ok
    if ok == 0:
      closePseudoConsole(hpc)
      discard closeHandle(inputRead); discard closeHandle(inputWrite)
      discard closeHandle(outputRead); discard closeHandle(outputWrite)
      return false
    # Drain up to 3s.
    var total = 0
    var buf: array[4096, char]
    let deadline = epochTime() + 3.0
    while epochTime() < deadline:
      var avail: int32 = 0
      if peekNamedPipe(outputRead, nil, 0, nil, addr avail, nil) != 0 and avail > 0:
        var got: int32 = 0
        if readFile(outputRead, addr buf[0], avail, addr got, nil) != 0 and got > 0:
          total += got.int
      else: sleep(20)
    discard waitForSingleObject(pi.hProcess, 5000)
    var code: int32 = 0
    discard getExitCodeProcess(pi.hProcess, code)
    echo "  child exit=", code, " outBytes=", total
    discard closeHandle(pi.hProcess); discard closeHandle(pi.hThread)
    closePseudoConsole(hpc)
    discard closeHandle(inputRead); discard closeHandle(inputWrite)
    discard closeHandle(outputRead); discard closeHandle(outputWrite)
    code == 0 and total > 0

  echo "consoleWindow=", getConsoleWindow().int
  let r1 = attempt("plain", false, false)
  echo "RESULT plain=", r1
  let r2 = attempt("allocFirst", true, false)
  echo "RESULT allocFirst=", r2
  let r3 = attempt("freeThenPlain", false, true)
  echo "RESULT freeThenPlain=", r3
  let r4 = attempt("freeThenAlloc", true, true)
  echo "RESULT freeThenAlloc=", r4
  quit(0)

main()
