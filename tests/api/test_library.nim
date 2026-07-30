discard """
  targets: "c"
  matrix: "; -d:providerStub"
"""
## Library API end-to-end: init a headless AgentSession against the stub
## provider, run a blocking prompt (with a tool call), collect callback
## events, run a colon command, close, and resume the saved session.
##
## Compiled twice by the matrix: the plain variant only exercises the
## init-failure path (no stub provider available); the `-d:providerStub`
## variant runs the full suite. XDG roots redirect config/data into a
## per-test fixture so nothing touches the developer's real 3code state.

import std/[json, os, strutils, unittest]
import threecode/[library, types]

const stubbed = defined(providerStub)

proc newFixture(name: string): string =
  result = getTempDir() / ("3code_libtest_" & name & "_" & $getCurrentProcessId())
  if dirExists(result): removeDir(result)
  createDir(result)
  createDir(result / "xdg" / "3code")
  createDir(result / "data")
  createDir(result / "run")

proc writeConfig(root: string) =
  writeFile(root / "xdg" / "3code" / "config", """
[settings]
current = "stub.stub-model"

[provider]
name = "stub"
url = "stub://provider"
key = "stub"
family = "glm"
models = "stub-model"
""")

proc isolateEnv(root: string) =
  putEnv("XDG_CONFIG_HOME", root / "xdg")
  putEnv("XDG_DATA_HOME", root / "data")
  # HOME redirect keeps `~/.3code/sandbox` (the policy template
  # materialized at session init) inside the fixture instead of the
  # developer's real home.
  createDir(root / "home")
  putEnv("HOME", root / "home")

suite "library: AgentSession":
  when not stubbed:
    test "init without a config raises AgentError":
      let root = newFixture("noconfig")
      isolateEnv(root)
      expect AgentError:
        discard initAgentSession(AgentOptions(cwd: root / "run"))
  else:
    test "blocking prompt runs tools and returns the reply":
      let root = newFixture("prompt")
      writeConfig(root)
      isolateEnv(root)
      # Response 1: the model asks for a bash tool call. Response 2: after
      # the tool result lands, the model closes with prose.
      writeFile(root / "run" / "stub_responses.json", $(%*[
        {"content": "",
         "tool_calls": [{
           "id": "call_1",
           "type": "function",
           "function": {"name": "bash",
                        "arguments": $(%*{"command": "echo hello-from-tool"})}}]},
        {"content": "tool says hello-from-tool",
         "contentChunks": ["tool says ", "hello-from-tool"]}
      ]))
      putEnv("THREECODE_STUB_RESPONSES", root / "run" / "stub_responses.json")

      var deltas, tools, retries, notices: seq[string]
      var dones: seq[Usage]
      let s = initAgentSession(AgentOptions(cwd: root / "run",
                                            experimental: true))

      # Callback surface wired up: deltas stream, tool results and turn
      # notices flow as aevTool/aevNotice (ANSI-free), aevDone carries the
      # per-call usage.
      s.onEvent = proc(ev: AgentEvent) =
        case ev.kind
        of aevDelta: deltas.add ev.text
        of aevTool: tools.add ev.text
        of aevRetry: retries.add ev.text
        of aevNotice: notices.add ev.text
        of aevDone: dones.add ev.usage
        else: discard

      check s.prompt("say hi with a tool") == "tool says hello-from-tool"
      check deltas.join("") == "tool says hello-from-tool"
      check dones.len >= 1
      check dones[^1].totalTokens > 0
      check tools.join("\n").contains("hello-from-tool")
      check s.usage.totalTokens > 0

      # Colon command round-trips through the same handler as the REPL.
      let toks = s.command(":tokens")
      check toks.contains("total")

      # Modal commands are refused, not deadlocked.
      check s.command(":provider add").contains("interactive")

      # The single sandbox policy file was materialized at init (from
      # the built-in default; no ~/.3code/sandbox existed in the
      # fixture) and `:sandbox show` reflects it.
      check fileExists(root / "run" / ".3code" / "sandbox")
      check s.command(":sandbox show").contains("/tmp")

      s.close()

    test "close persists a resumable session":
      let root = newFixture("resume")
      writeConfig(root)
      isolateEnv(root)
      # The stub provider's response index is process-global; pad the file
      # with the two entries the first test consumed so the pointer lands
      # on this test's replies.
      writeFile(root / "run" / "stub_responses.json", $(%*[
        {"content": "pad"}, {"content": "pad"},
        {"content": "first reply"}
      ]))
      putEnv("THREECODE_STUB_RESPONSES", root / "run" / "stub_responses.json")

      let s1 = initAgentSession(AgentOptions(cwd: root / "run",
                                             experimental: true))
      check s1.prompt("first") == "first reply"
      let savePath = s1.state.savePath
      s1.close()
      check fileExists(savePath)

      writeFile(root / "run" / "stub_responses.json", $(%*[
        {"content": "pad"}, {"content": "pad"}, {"content": "pad"},
        {"content": "second reply"}
      ]))
      let s2 = initAgentSession(AgentOptions(cwd: root / "run", resume: true,
                                             experimental: true))
      # History came back: system + user + assistant from the first session.
      check s2.messages.len >= 3
      check s2.prompt("second") == "second reply"
      s2.close()

    test "unknown model raises AgentError":
      let root = newFixture("badmodel")
      writeConfig(root)
      isolateEnv(root)
      putEnv("THREECODE_STUB_RESPONSES", root / "run" / "stub_responses.json")
      expect AgentError:
        discard initAgentSession(AgentOptions(cwd: root / "run",
                                              model: "stub.nonexistent",
                                              experimental: true))
