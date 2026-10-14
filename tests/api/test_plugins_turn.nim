discard """
  targets: "c"
  matrix: "-d:providerStub"
"""
## In-situ plugin coverage: a full headless AgentSession turn against the
## stub provider with the fixture plugin loaded through the real
## discovery path. Proves the wired call sites end to end: [plugins]
## config parsing, prompt mutation, tool-call veto pairing, plugin-tool
## registration + execution, and the session/turn async events.
## The direct hook-level coverage lives in tests/core/test_plugins.nim.

import std/[json, os, strutils, unittest]
import ../plugin_helpers
import threecode/library

suite "plugins: full turn":
  when defined(providerStub):
    var
      root: string
      logPath: string

    setup:
      if not dirExists(root):
        root = getTempDir() / "3code_plugin_turn_" & $getCurrentProcessId()
        logPath = root / "fixture.log"
        pluginResetLog(logPath)
        createDir(root / "run")
        createDir(root / "xdg" / "3code")
        createDir(root / "tmp")
        buildPluginFixtures(root / "data")
        writeFile(root / "xdg" / "3code" / "config", """
[settings]
current = "stub.stub-model"

[provider]
name = "stub"
url = "stub://provider"
key = "stub"
family = "glm"
models = "stub-model"

[plugins]
tools = "on"
debug = "on"
""")
        putEnv("XDG_CONFIG_HOME", root / "xdg")
        putEnv("XDG_DATA_HOME", root / "data")
        putEnv("TMPDIR", root / "tmp")
        putEnv("TC_FIXTURE_LOG", logPath)
        putEnv("THREECODE_PLUGIN_SYNC_MS", "3000")
        putEnv("THREECODE_DEBUG_LOG", root / "dbg.log")

    test "veto pairs, plugin tool executes, prompt mutates, events fire":
      putEnv("TC_FIXTURE_MODE", "veto")
      # turn 1: a write (vetoed by the plugin, tool result = its note),
      # then a fixture_echo call (executed by the plugin), then prose.
      writeFile(root / "run" / "stub_responses.json", $(%*[
        {"content": "",
         "tool_calls": [{
           "id": "call_1",
           "type": "function",
           "function": {"name": "write",
                        "arguments": $(%*{"path": "x.nim", "body": "x"})}}]},
        {"content": "",
         "tool_calls": [{
           "id": "call_2",
           "type": "function",
           "function": {"name": "fixture_echo",
                        "arguments": $(%*{"text": "hi"})}}]},
        {"content": "all done"}
      ]))
      putEnv("THREECODE_STUB_RESPONSES", root / "run" / "stub_responses.json")

      let s = initAgentSession(AgentOptions(cwd: root / "run",
                                            experimental: true))
      defer: s.close()
      let reply = s.prompt("hello")

      check reply == "all done"
      # prompt hook rewrote the text before the message was appended
      var userText = ""
      for m in s.messages.getElems:
        if m{"role"}.getStr == "user":
          userText = m{"content"}.getStr
          break
      check "hello [fixture]" in userText
      # the veto paired with the plugin's note and nothing was written
      var vetoSeen = false
      var echoResult = ""
      for m in s.messages.getElems:
        if m{"role"}.getStr == "tool":
          let c = m{"content"}.getStr
          if "fixture: writes are frozen" in c: vetoSeen = true
          if "fixture_echo got:" in c: echoResult = c
      check vetoSeen
      check not fileExists(root / "run" / "x.nim")
      # the registered plugin tool executed with its args
      check "hi" in echoResult
      # async events: session start + turn start/end landed on the log
      check pluginWaitForLog(logPath,
        proc(l: string): bool = l.startsWith("session|stub"))
      check pluginWaitForLog(logPath,
        proc(l: string): bool = l.startsWith("turnstart|1"))
      check pluginWaitForLog(logPath,
        proc(l: string): bool = l.startsWith("turnend|1"))
      # [plugins] debug opened the trace channel for plugin lines only
      # (no -D flag): the forced debugOut sink received hook traces.
      check fileExists(root / "dbg.log")
      let dbg = readFile(root / "dbg.log")
      check "tc_on_prompt" in dbg
      check "tool_pre write verdict=1" in dbg
