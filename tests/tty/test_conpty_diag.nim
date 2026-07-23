import std/[json, os, strutils, unittest]
import tty_expect

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
  test "configured provider startup under ConPTY":
    let root = newFixture("diag_cfg")
    writeConfiguredProvider(root)
    writeStubResponses(root, %*[{"role": "assistant", "content": "ok"}])
    let stub = getCurrentDir() / "build" / "3code_stub" & (when defined(windows): ".exe" else: "")
    let tty = newTtySession(stub,
        args = ["-x", "-i"],
        cwd = root / "run",
        env = stubEnv(root, root / "run" / "stub_responses.json"))
    defer: tty.close()
    let got = tty.expect("\u276f", timeoutMs = 5000)
    echo "saw prompt: ", got
    echo "exited: ", tty.exited, " code: ", tty.exitCode
    echo "raw len: ", tty.raw.len
    if tty.raw.len > 0:
      echo "raw tail: [", tty.cleanRaw()[max(0, tty.cleanRaw().len - 400) ..< tty.cleanRaw().len], "]"
