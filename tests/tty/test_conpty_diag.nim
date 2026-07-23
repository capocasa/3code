## ConPTY diagnostic: hard-asserting probe to localize the 0xC0000142
## (STATUS_DLL_INIT_FAILED) failure seen only when the real tty tests spawn
## the stub via ensureStubBinary(). The prior diags had no assertions, so a
## dead child produced a false PASS. This one fails loudly.
import std/[json, os, unittest]
import tty_expect
import stub_helpers

proc diagEnv*(extra: openArray[EnvVar] = []): seq[EnvVar] =
  ## Minimal env that still lets a Windows child resolve system DLLs: inherit
  ## PATH and the loader-critical system vars, plus anything the caller adds.
  result.add((key: "TERM", val: "xterm-256color"))
  result.add((key: "PATH", val: getEnv("PATH")))
  for k in ["SystemRoot", "windir", "TEMP", "TMP", "COMSPEC", "PATHEXT",
            "APPDATA", "LOCALAPPDATA", "PROGRAMDATA", "USERPROFILE"]:
    let v = getEnv(k)
    if v.len > 0:
      result.add((key: k, val: v))
  for e in extra:
    result.add e

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

suite "conpty diagnostic":
  test "A: cmd.exe echo under ConPTY":
    let tty = newTtySession(getEnv("WINDIR") / "System32" / "cmd.exe",
                            args = ["/c", "echo hello_conpty"],
                            env = diagEnv())
    defer: tty.close()
    let got = tty.expect("hello_conpty", timeoutMs = 5000)
    echo "A saw output: ", got, " | exited: ", tty.exited, " code: ", tty.exitCode
    echo "A raw: [", tty.cleanRaw(), "]"
    check got

  test "B: stub -v with minimal inherited env":
    let stub = ensureStubBinary()
    echo "B stub path: ", stub, " exists: ", fileExists(stub)
    let tty = newTtySession(stub, args = ["-v"], env = diagEnv())
    defer: tty.close()
    discard tty.waitForOutput(5000)
    echo "B exited: ", tty.exited, " code: ", tty.exitCode
    echo "B raw len: ", tty.raw.len
    echo "B raw: [", tty.cleanRaw(), "]"
    check tty.raw.len > 0
    check not tty.exited or tty.exitCode == 0

  test "C: stub interactive with full test_quit_signals env":
    let root = newFixture("diag_full")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[{"role": "assistant", "content": "ok"}])
    let stub = ensureStubBinary()
    let tty = newTtySession(stub,
        args = ["-x", "-i"],
        cwd = root / "run",
        env = stubEnv(root, root / "run" / "stub_responses.json"))
    defer: tty.close()
    let got = tty.expect("\u276f", timeoutMs = 8000)
    echo "C saw prompt: ", got, " | exited: ", tty.exited, " code: ", tty.exitCode
    echo "C raw len: ", tty.raw.len
    if tty.raw.len > 0:
      echo "C raw tail: [", tty.cleanRaw()[max(0, tty.cleanRaw().len - 500) ..< tty.cleanRaw().len], "]"
    check got
