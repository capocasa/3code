## Standalone ConPTY smoke using NAMED pipes (CreateNamedPipeW), mirroring
## node-pty's approach (which works on GHA windows runners). Anonymous pipes
## (CreatePipe) cause the child to die with 0xC0000142 (STATUS_DLL_INIT_FAILED)
## on the GHA runner; named pipes do not.
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
  INVALID_HANDLE_VALUE_INT = -1

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

proc mkPipeName(tag: string): string =
  "\\\\.\\pipe\\conpty_smoke_" & $getCurrentProcessId() & "_" & tag

proc main() =
  # Named pipe server ends (node-pty pattern): CreateNamedPipeW with
  # PIPE_ACCESS_INBOUND | PIPE_ACCESS_OUTBOUND | FILE_FLAG_FIRST_PIPE_INSTANCE.
  let openMode = PIPE_ACCESS_INBOUND or PIPE_ACCESS_OUTBOUND or
                 FILE_FLAG_FIRST_PIPE_INSTANCE
  var sa = SECURITY_ATTRIBUTES(nLength: sizeof(SECURITY_ATTRIBUTES).int32,
                               bInheritHandle: 0)
  let inName = mkPipeName("in")
  let outName = mkPipeName("out")
  let inNameW = newWideCString(inName)
  let outNameW = newWideCString(outName)
  let hIn = createNamedPipeW(inNameW, openMode,
      PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT, 1,
      128 * 1024, 128 * 1024, 30000, addr sa)
  let hOut = createNamedPipeW(outNameW, openMode,
      PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT, 1,
      128 * 1024, 128 * 1024, 30000, addr sa)
  echo "named pipes: hIn=", hIn.int, " hOut=", hOut.int
  if hIn.int == INVALID_HANDLE_VALUE_INT or hOut.int == INVALID_HANDLE_VALUE_INT:
    echo "CreateNamedPipeW failed le=", getLastError(); quit(1)

  var hpc: HPCON
  let rc = createPseudoConsole(COORD(x: 80.int16, y: 30.int16),
                               hIn, hOut, 0, addr hpc)
  echo "createPseudoConsole rc=", rc, " hpc=", hpc.int
  if rc != 0: quit("createPseudoConsole failed", 1)

  # Wait for the conhost (spawned by CreatePseudoConsole) to connect to both
  # named pipe server ends. node-pty calls ConnectNamedPipe here.
  echo "ConnectNamedPipe hIn rc=", connectNamedPipe(hIn, nil), " le=", getLastError()
  echo "ConnectNamedPipe hOut rc=", connectNamedPipe(hOut, nil), " le=", getLastError()

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
  let cmd = getEnv("WINDIR") & "\\System32\\cmd.exe /c echo conpty_named_ok"
  let cmdW = newWideCString(cmd)
  let appW: WideCString = nil
  let ok = createProcessW(appW, cmdW, nil, nil, 0,
      EXTENDED_STARTUPINFO_PRESENT, nil, nil, si.startupInfo, pi)
  echo "createProcessW ok=", ok, " le=", getLastError()
  if ok == 0: quit("createProcessW failed", 1)

  # Drain output for up to 3s.
  var total = 0
  var buf: array[4096, char]
  let deadline = epochTime() + 3.0
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
  echo "total output bytes: ", total

  discard waitForSingleObject(pi.hProcess, 5000)
  var code: int32 = 0
  discard getExitCodeProcess(pi.hProcess, code)
  echo "child exit code: ", code
  discard closeHandle(pi.hProcess)
  discard closeHandle(pi.hThread)
  closePseudoConsole(hpc)
  discard closeHandle(hIn)
  discard closeHandle(hOut)
  if code == 0 and total > 0:
    echo "RESULT: SUCCESS"; quit(0)
  else:
    echo "RESULT: FAILURE"; quit(1)

main()
