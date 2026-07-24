## ConPTY diagnostic: hard-asserting probe to localize the 0xC0000142
## (STATUS_DLL_INIT_FAILED) failure. The prior diags had no assertions, so a
## dead child produced a false PASS. This one fails loudly.
import std/[json, os, strutils, unittest]
import tty_expect
import stub_helpers

proc newFixture(name: string): string =
  result = getCurrentDir() / "testdata/output/tty" / (name & "_" & $getCurrentProcessId())
  if dirExists(result): removeDir(result)
  createDir(result); createDir(result / "data"); createDir(result / "run")

proc writeConfiguredProvider(root: string) =
  createDir(root / "xdg" / "3code")
  writeFile(root / "xdg" / "3code" / "config", """
[settings]
current = "stub.stub-model"
search-url = "http://127.0.0.1:1/?q="

[provider]
name = "stub"
url = "stub://provider"
key = "stub"
family = "glm"
models = "stub-model"
""")

proc writeStubResponses(root: string, responses: JsonNode) =
  writeFile(root / "run" / "stub_responses.json", $responses)

proc stubEnv(root, responsesPath: string): seq[EnvVar] =
  createDir(root / "tmp")
  @[
    (key: "TERM", val: "xterm-256color"),
    (key: "PATH", val: getEnv("PATH")),
    (key: "HOME", val: root),
    (key: "TMPDIR", val: root / "tmp"),
    (key: "XDG_CONFIG_HOME", val: root / "xdg"),
    (key: "XDG_DATA_HOME", val: root / "data"),
    (key: "THREECODE_STUB_RESPONSES", val: responsesPath),
  ]

proc diagEnv*(extra: openArray[EnvVar] = []): seq[EnvVar] =
  result.add((key: "TERM", val: "xterm-256color"))
  result.add((key: "PATH", val: getEnv("PATH")))
  for k in ["SystemRoot", "windir", "TEMP", "TMP", "COMSPEC", "PATHEXT",
            "APPDATA", "LOCALAPPDATA", "PROGRAMDATA", "USERPROFILE"]:
    let v = getEnv(k)
    if v.len > 0:
      result.add((key: k, val: v))
  for e in extra:
    result.add e

when defined(windows):
  import winlean

  proc plainSpawnEcho(cmdLine: string): tuple[ok: bool, code: int, outLen: int] =
    ## Plain CreateProcessW (NO ConPTY, NO attribute list) capturing stdout
    ## via a pipe. Isolates runner/session issues from the ConPTY mechanism.
    ## If this works but ConPTY doesn't, the bug is in the pseudoconsole path.
    var sa = SECURITY_ATTRIBUTES(nLength: sizeof(SECURITY_ATTRIBUTES).int32,
                                 bInheritHandle: 1)
    var rd, wr: Handle
    doAssert createPipe(rd, wr, sa, 0) != 0
    discard setHandleInformation(rd, HANDLE_FLAG_INHERIT, 0)
    var si = STARTUPINFO(cb: sizeof(STARTUPINFO).int32,
                         dwFlags: 0x100,  # STARTF_USESTDHANDLES
                         hStdOutput: wr, hStdError: wr)
    var pi: PROCESS_INFORMATION
    let cmdW = newWideCString(cmdLine)
    let appW: WideCString = nil
    let ok = createProcessW(appW, cmdW, nil, nil, 1, 0, nil, nil, si, pi)
    if ok == 0:
      echo "  plainSpawn CreateProcessW failed le=", getLastError()
      return (false, -1, 0)
    discard closeHandle(wr)
    var buf: array[4096, char]
    var total = 0
    var got: int32 = 0
    while readFile(rd, addr buf[0], buf.len.int32, addr got, nil) != 0 and got > 0:
      total += got.int
    discard closeHandle(rd)
    discard waitForSingleObject(pi.hProcess, 10000)
    var code: int32 = 0
    discard getExitCodeProcess(pi.hProcess, code)
    discard closeHandle(pi.hProcess)
    discard closeHandle(pi.hThread)
    (true, code.int, total)

when defined(windows):
  suite "conpty diagnostic":
    test "P: plain CreateProcessW (no ConPTY) echo":
      # Baseline: does process creation work at all on this runner?
      let r = plainSpawnEcho(getEnv("COMSPEC") & " /c echo plain_ok")
      echo "P ok=", r.ok, " code=", r.code, " outLen=", r.outLen
      check r.ok and r.code == 0 and r.outLen > 0

    test "B: stub -v with minimal inherited env":
      let stub = ensureStubBinary()
      echo "B stub path: ", stub, " exists: ", fileExists(stub)
      let tty = newTtySession(stub, args = ["-v"], env = diagEnv())
      defer: tty.close()
      discard tty.waitForOutput(8000)
      echo "B exited: ", tty.exited, " code: ", tty.exitCode
      echo "B raw len: ", tty.raw.len
      echo "B raw repr: ", repr(tty.raw)
      check tty.raw.len > 0

    test "C: stub interactive, send input to prime conhost relay":
      let root = newFixture("diag_full")
      writeConfiguredProvider(root)
      writeStubResponses(root, %*[{"role": "assistant", "content": "ok"}])
      let stub = ensureStubBinary()
      let tty = newTtySession(stub,
          args = ["-x", "-i"],
          cwd = root / "run",
          env = stubEnv(root, root / "run" / "stub_responses.json"))
      defer: tty.close()
      discard tty.waitForOutput(2000)
      echo "C pre-send raw repr: ", repr(tty.raw)
      tty.send("hi")
      let got = tty.expect("\u276f", timeoutMs = 10000)
      echo "C saw prompt: ", got, " | exited: ", tty.exited, " code: ", tty.exitCode
      echo "C raw repr: ", repr(tty.raw)[max(0, repr(tty.raw).len - 800) ..< repr(tty.raw).len]
      check got
else:
  suite "conpty diagnostic":
    test "conpty diagnostic is windows-only":
      discard
