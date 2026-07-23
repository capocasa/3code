## Standalone ConPTY smoke — faithful MS-sample reproduction (anonymous pipes)
## plus the lpValue=hpc semantic. Run directly to isolate 0xC0000142/0xC0000138.
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

proc attempt(label: string; lpValueByAddr: bool): bool =
  ## lpValueByAddr: true = &hpc (generic semantic); false = hpc value (MS sample).
  echo "--- ", label, " (lpValueByAddr=", lpValueByAddr, ")"
  var sa = SECURITY_ATTRIBUTES(nLength: sizeof(SECURITY_ATTRIBUTES).int32,
                               bInheritHandle: 0)
  # input pipe: parent writes to inWrite, pseudoconsole reads inRead.
  var inRead, inWrite, outRead, outWrite: Handle
  doAssert createPipe(inRead, inWrite, sa, 0) != 0
  doAssert createPipe(outRead, outWrite, sa, 0) != 0
  var hpc: HPCON
  let rc = createPseudoConsole(COORD(x: 80.int16, y: 30.int16),
                               inRead, outWrite, 0, addr hpc)
  echo "  createPseudoConsole rc=", rc, " hpc=", hpc.int
  if rc != 0:
    discard closeHandle(inRead); discard closeHandle(inWrite)
    discard closeHandle(outRead); discard closeHandle(outWrite)
    return false
  # Close PTY-end handles immediately (ConHost holds dup'd copies).
  discard closeHandle(inRead)
  discard closeHandle(outWrite)
  var attrSize: SIZE_T = 0
  discard initializeProcThreadAttributeList(nil, 1, 0, addr attrSize)
  var attrList = cast[pointer](alloc0(attrSize))
  doAssert initializeProcThreadAttributeList(attrList, 1, 0, addr attrSize) != 0
  let lpVal = if lpValueByAddr: cast[pointer](unsafeAddr hpc)
              else: cast[pointer](hpc.Handle)
  let updRc = updateProcThreadAttribute(attrList, 0,
      PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE.uint, lpVal,
      sizeof(HPCON).SIZE_T, nil, nil)
  echo "  updAttr rc=", updRc, " le=", getLastError()
  doAssert updRc != 0
  var si = STARTUPINFOEX(startupInfo: STARTUPINFO(cb: sizeof(STARTUPINFOEX).int32))
  si.lpAttributeList = attrList
  var pi: PROCESS_INFORMATION
  let cmd = getEnv("WINDIR") & "\\System32\\cmd.exe /c echo conpty_ok"
  let cmdW = newWideCString(cmd)
  let appW: WideCString = nil
  let ok = createProcessW(appW, cmdW, nil, nil, 0,
      EXTENDED_STARTUPINFO_PRESENT, nil, nil, si.startupInfo, pi)
  echo "  createProcessW ok=", ok, " le=", getLastError()
  if ok == 0:
    closePseudoConsole(hpc)
    discard closeHandle(inWrite); discard closeHandle(outRead)
    return false
  var total = 0
  var buf: array[4096, char]
  let deadline = epochTime() + 3.0
  while epochTime() < deadline:
    var avail: int32 = 0
    if peekNamedPipe(outRead, nil, 0, nil, addr avail, nil) != 0 and avail > 0:
      var got: int32 = 0
      if readFile(outRead, addr buf[0], avail, addr got, nil) != 0 and got > 0:
        total += got.int
        var s = newString(got)
        copyMem(s[0].addr, buf[0].addr, got)
        echo "  child output: [", s, "]"
    else:
      sleep(20)
  discard waitForSingleObject(pi.hProcess, 5000)
  var code: int32 = 0
  discard getExitCodeProcess(pi.hProcess, code)
  echo "  child exit=", code, " outBytes=", total
  discard closeHandle(pi.hProcess); discard closeHandle(pi.hThread)
  closePseudoConsole(hpc)
  discard closeHandle(inWrite); discard closeHandle(outRead)
  code == 0 and total > 0

proc main() =
  let r1 = attempt("byAddr (&hpc)", true)
  echo "RESULT byAddr=", r1
  let r2 = attempt("byValue (hpc)", false)
  echo "RESULT byValue=", r2
  quit(0)

main()
