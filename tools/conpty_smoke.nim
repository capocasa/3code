## Standalone ConPTY smoke — NAMED pipes + ConnectNamedPipe (node-pty pattern),
## now with the lpValue=hpc fix that wasn't in place when named pipes were last
## tried (they blocked on ConnectNamedPipe). Retest whether the conhost
## connects and relays child stdout with named pipes.
when not defined(windows):
  echo "windows-only"
  quit(0)

import std/[os, times]
import winlean

const
  PIPE_ACCESS_INBOUND = 0x00000001'i32
  PIPE_ACCESS_OUTBOUND = 0x00000002'i32
  FILE_FLAG_FIRST_PIPE_INSTANCE = 0x00080000'i32
  PIPE_TYPE_BYTE = 0x00000000'i32
  PIPE_READMODE_BYTE = 0x00000000'i32
  PIPE_WAIT = 0x00000000'i32

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
proc createNamedPipeW(lpName: WideCString; dwOpenMode, dwPipeMode,
    nMaxInstances, nOutBufferSize, nInBufferSize, nDefaultTimeOut: int32;
    lpSecurityAttributes: ptr SECURITY_ATTRIBUTES): Handle {.stdcall,
    dynlib: "kernel32", importc: "CreateNamedPipeW".}
proc connectNamedPipe(hNamedPipe: Handle; lpOverlapped: pointer): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "ConnectNamedPipe".}
proc peekNamedPipe(hNamedPipe: Handle; lpBuffer: pointer; nBufferSize: DWORD;
    lpBytesRead, lpTotalBytesAvail, lpBytesLeftThisMessage: ptr int32): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "PeekNamedPipe".}

proc mkName(tag: string): string =
  "\\\\.\\pipe\\conpty_smoke_" & $getCurrentProcessId() & "_" & tag

proc main() =
  var sa = SECURITY_ATTRIBUTES(nLength: sizeof(SECURITY_ATTRIBUTES).int32,
                               bInheritHandle: 0)
  let openMode = PIPE_ACCESS_INBOUND or PIPE_ACCESS_OUTBOUND or
                 FILE_FLAG_FIRST_PIPE_INSTANCE
  let pipeMode = PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT
  let inNameW = newWideCString(mkName("in"))
  let outNameW = newWideCString(mkName("out"))
  let hIn = createNamedPipeW(inNameW, openMode, pipeMode, 1,
                             128*1024, 128*1024, 30000, addr sa)
  let hOut = createNamedPipeW(outNameW, openMode, pipeMode, 1,
                              128*1024, 128*1024, 30000, addr sa)
  echo "named pipes hIn=", hIn.int, " hOut=", hOut.int
  if hOut.int == -1 or hIn.int == -1:
    echo "CreateNamedPipeW failed le=", getLastError(); quit(1)

  var hpc: HPCON
  let rc = createPseudoConsole(COORD(x: 80.int16, y: 30.int16),
                               hIn, hOut, 0, addr hpc)
  echo "createPseudoConsole rc=", rc, " hpc=", hpc.int
  if rc != 0: quit("createPseudoConsole failed", 1)

  # ConnectNamedPipe: blocks until the conhost connects as a client. With the
  # lpValue=hpc fix in place the conhost should now actually attach.
  echo "ConnectNamedPipe hIn..."
  let c1 = connectNamedPipe(hIn, nil)
  echo "ConnectNamedPipe hIn rc=", c1, " le=", getLastError()
  echo "ConnectNamedPipe hOut..."
  let c2 = connectNamedPipe(hOut, nil)
  echo "ConnectNamedPipe hOut rc=", c2, " le=", getLastError()

  var attrSize: SIZE_T = 0
  discard initializeProcThreadAttributeList(nil, 1, 0, addr attrSize)
  var attrList = cast[pointer](alloc0(attrSize))
  doAssert initializeProcThreadAttributeList(attrList, 1, 0, addr attrSize) != 0
  doAssert updateProcThreadAttribute(attrList, 0,
      PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE.uint, cast[pointer](hpc.Handle),
      sizeof(HPCON).SIZE_T, nil, nil) != 0

  var si = STARTUPINFOEX(startupInfo: STARTUPINFO(cb: sizeof(STARTUPINFOEX).int32))
  si.lpAttributeList = attrList
  var pi: PROCESS_INFORMATION
  let cmd = getEnv("WINDIR") & "\\System32\\cmd.exe /c echo conpty_named_ok"
  let cmdW = newWideCString(cmd)
  let appW: WideCString = nil
  let ok = createProcessW(appW, cmdW, nil, nil, 0,
      EXTENDED_STARTUPINFO_PRESENT, nil, nil, si.startupInfo, pi)
  echo "createProcessW ok=", ok, " le=", getLastError()
  if ok == 0: quit("createProcessW failed", 1)

  var total = 0
  var buf: array[4096, char]
  let deadline = epochTime() + 5.0
  while epochTime() < deadline:
    var avail: int32 = 0
    if peekNamedPipe(hOut, nil, 0, nil, addr avail, nil) != 0 and avail > 0:
      var got: int32 = 0
      if readFile(hOut, addr buf[0], avail, addr got, nil) != 0 and got > 0:
        total += got.int
        var s = newString(got)
        copyMem(s[0].addr, buf[0].addr, got)
        echo "child output: [", s, "]"
    else:
      sleep(20)
  discard waitForSingleObject(pi.hProcess, 5000)
  var code: int32 = 0
  discard getExitCodeProcess(pi.hProcess, code)
  echo "child exit=", code, " outBytes=", total
  discard closeHandle(pi.hProcess); discard closeHandle(pi.hThread)
  closePseudoConsole(hpc)
  discard closeHandle(hIn); discard closeHandle(hOut)
  quit(0)

main()