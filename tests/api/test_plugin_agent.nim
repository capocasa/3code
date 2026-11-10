discard """
  targets: "c"
  matrix: "; -d:providerStub"
"""
## The plugin agent backend (pluginagent.nim) end to end against the
## stub provider: install the services, drive them exactly like a
## plugin frontend would (open, start, poll events, command, scrollback,
## close), and check the busy/lastError contracts. The plain variant
## compiles only the not-installed contracts (no stub provider there).
## XDG roots redirect config/data/plugins so the fixture plugin loads
## through the real discovery path inside initAgentSession.

import std/[json, os, strutils, times, unittest]
import threecode/[plugins, pluginagent, pluginabi]

const stubbed = defined(providerStub)

when stubbed:
  import ../plugin_helpers
  import threecode/[library, types, util]

  var root: string

  proc newFixture(name: string): string =
    result = getTempDir() / ("3code_pluginagent_" & name & "_" &
                             $getCurrentProcessId())
    if dirExists(result): removeDir(result)
    createDir(result)
    createDir(result / "xdg" / "3code")
    createDir(result / "data" / "3code")
    createDir(result / "run")
    createDir(result / "tmp")

  proc writeConfig(r: string) =
    writeFile(r / "xdg" / "3code" / "config", """
[settings]
current = "stub.stub-model"

[provider]
name = "stub"
url = "stub://provider"
key = "stub"
family = "glm"
models = "stub-model"
""")

  proc isolateEnv(r: string) =
    putEnv("XDG_CONFIG_HOME", r / "xdg")
    putEnv("XDG_DATA_HOME", r / "data")
    putEnv("TMPDIR", r / "tmp")
    putEnv("TC_FIXTURE_LOG", r / "fixture.log")

  proc stubReplies() =
    # one entry per model call the suite makes, in order; the stub's
    # response index is process-global and never resets
    var arr = newJArray()
    for r in ["first reply", "second reply", "third reply", "fourth"]:
      arr.add %*{"content": r}
    writeFile(root / "run" / "stub_responses.json", $arr)
    putEnv("THREECODE_STUB_RESPONSES", root / "run" / "stub_responses.json")

  proc pollUntil(maxMs: int; pred: proc (): bool): bool =
    let deadline = epochTime() + maxMs.float / 1000.0
    while epochTime() < deadline:
      if pred(): return true
      sleep(20)
    false

suite "plugin agent services":
  when not stubbed:
    test "services are unwired until installPluginAgentServices":
      check plugins.pluginAgentServices.open == nil
      check plugins.pluginAgentServices.pollEvent == nil

  else:
    setup:
      if root.len == 0:
        root = newFixture("main")
        writeConfig(root)
        isolateEnv(root)
        buildPluginFixtures(root / "data")
        stubReplies()
        installPluginAgentServices()

    test "open the session; double open refused":
      let sv = plugins.pluginAgentServices
      let opts = $(%*{"cwd": root / "run"})
      check sv.open(opts) == 0.cint
      check sv.open("{}") == 1.cint
      check sv.busy() == 0.cint

    test "turn events stream through the ring":
      let sv = plugins.pluginAgentServices
      var sawUser = false
      var sawDone = false
      check sv.start("first") == 0.cint
      check sv.busy() == 1.cint
      var rounds = 0
      while not sawDone and rounds < 500:
        inc rounds
        var ev: TcAgentEvent
        while sv.pollEvent(addr ev) == 1.cint:
          if ev.kind == taeUser and tcView(ev.text) == "first":
            sawUser = true
          if ev.kind == taeDone:
            sawDone = true
          if ev.kind == taeError:
            checkpoint "error event: " & tcView(ev.text)
        if not sawDone: sleep(20)
      check sawUser
      check sawDone
      check pollUntil(10_000, proc (): bool = sv.busy() == 0.cint)

    test "commands and scrollback while idle":
      let sv = plugins.pluginAgentServices
      var body = ""
      check sv.command(":tokens", body) == 0.cint
      check body.len > 0
      check sv.command(":quit", body) == 3.cint  # quitting is close()'s job
      var scroll = ""
      check sv.scrollback(scroll) == 0.cint
      let rows = parseJson(scroll)
      check rows.kind == JArray
      check rows.len >= 2
      check rows[0]{"role"}.getStr == "user"
      check rows[^1]{"role"}.getStr == "assistant"
      check "first reply" in rows[^1]{"content"}.getStr

    test "second turn, then close":
      let sv = plugins.pluginAgentServices
      check sv.start("second") == 0.cint
      check pollUntil(10_000, proc (): bool = sv.busy() == 0.cint)
      var sawDone = false
      var ev: TcAgentEvent
      while sv.pollEvent(addr ev) == 1.cint:
        if ev.kind == taeDone: sawDone = true
      check sawDone
      check sv.closeImpl() == 0.cint
      check sv.closeImpl() == 1.cint  # nothing open anymore

    test "resume, busy guard, cancel contract":
      let sv = plugins.pluginAgentServices
      let resumeOpts = $(%*{"resume": true, "cwd": root / "run"})
      check sv.open(resumeOpts) == 0.cint
      # continue turn (empty prompt): kick, then the transcript services
      # refuse while it runs (or it already finished — the stub is fast)
      check sv.start("") == 0.cint
      var body = ""
      let rc = sv.command(":tokens", body)
      check rc == 1.cint or sv.busy() == 0.cint
      check pollUntil(10_000, proc (): bool = sv.busy() == 0.cint)
      # cancel while idle: reported idle, nothing crashed
      check sv.cancel() in [0.cint, 1.cint]
      discard sv.closeImpl()
