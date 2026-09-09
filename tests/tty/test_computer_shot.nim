discard """
  disabled: "win"
"""
## Computer use through the real binary in a PTY: `:computer`-free config
## arming, a scripted `screenshot` call (capture faked via
## THREECODE_SCREENSHOT_SRC), the `· shot` transcript banner, and the
## model driving the generated `shot` script through the bash tool — the
## real sandbox path, DISPLAY passthrough and all. The faked 16x12 frame
## can never match the real display geometry, so `shot` must answer with
## the loud stale-frame error naming screenshot(). Needs a live X11
## session (plus xdotool and a capture tool); skips headless.
import std/[json, os, sequtils, unittest]
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
computer = "on"

[provider]
name = "stub"
url = "stub://provider"
key = "stub"
family = "glm"
models = "stub-model"

[params]
provider = "stub"
model = "stub-model"
vision = "on"
""")

proc stubEnv(root, responsesPath: string): seq[EnvVar] =
  createDir(root / "tmp")
  @[
    (key: "XDG_DATA_HOME", val: root / "xdg"),
    (key: "XDG_CONFIG_HOME", val: root / "xdg"),
    (key: "XDG_CACHE_HOME", val: root / "xdg" / "cache"),
    (key: "TMPDIR", val: root / "tmp"),
    (key: "HOME", val: root),
    (key: "PATH", val: getEnv("PATH")),
    (key: "DISPLAY", val: getEnv("DISPLAY")),
    (key: "THREECODE_STUB_RESPONSES", val: responsesPath),
    (key: "THREECODE_STUB_STREAM", val: "1"),
    (key: "THREECODE_SCREENSHOT_SRC", val: getCurrentDir() / "testdata/images/tiny.png"),
  ]

proc x11Ready(): bool =
  getEnv("DISPLAY").len > 0 and findExe("xdotool").len > 0 and
    ["import", "maim", "scrot"].anyIt(findExe(it).len > 0)

suite "computer use via shot (real binary)":
  test "screenshot banner, shot stale-frame error through the sandbox":
    if not x11Ready(): skip()
    let root = newFixture("computer_shot")
    writeConfiguredProvider(root)
    # The session id is unknown up front, so the model's bash command
    # reaches the script through the glob $TMPDIR/3code-shot-*/shot.
    let shotCmd = "\"$TMPDIR\"/3code-shot-*/shot click 640 360"
    writeFile(root / "run" / "stub_responses.json", $(%*[
      {"content": "", "tool_calls": [{
        "id": "call_1", "type": "function",
        "function": {"name": "screenshot", "arguments": "{}"}}]},
      {"content": "", "tool_calls": [{
        "id": "call_2", "type": "function",
        "function": {"name": "bash",
                     "arguments": $(%*{"command": shotCmd})}}]},
      {"content": "stale confirmed", "contentChunks": ["stale confirmed"]}
    ]))
    let stub = ensureStubBinary()
    let tty = newTtySession(stub,
                            args = ["-x", "-i"],
                            cwd = root / "run",
                            env = stubEnv(root, root / "run" / "stub_responses.json"),
                            keepHistory = true)
    defer: tty.close()
    tty.expect "\u276f"
    tty.send "look and click\n"
    # Capture receipt: one-line banner, no base64 on screen.
    tty.expectInHistory "shot 16x12 -> 16x12"
    # The bash-driven shot script ran for real: faked 16x12 frame vs the
    # live display geometry is a stale frame, loudly.
    tty.expectInHistory "stale frame"
    tty.expectInHistory "screenshot()"
    tty.expectInHistory "stale confirmed"
    tty.drain(200)
    tty.expect "\u276f"
