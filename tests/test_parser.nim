import std/[unittest, json, strutils]
import threecode/[types, actions]

suite "glm/qwen dispatch":
  test "bash takes a command string":
    let act = toolCallToAction("glm", "bash", %*{"command": "nimble test"})
    check act.kind == akBash
    check act.body == "nimble test"

  test "bash carries optional stdin":
    let act = toolCallToAction("qwen", "bash", %*{"command": "cat", "stdin": "hi"})
    check act.kind == akBash
    check act.body == "cat"
    check act.stdin == "hi"

  test "write takes path and body":
    let act = toolCallToAction("glm", "write", %*{"path": "x.nim", "body": "echo 1"})
    check act.kind == akWrite
    check act.path == "x.nim"
    check act.body == "echo 1"

  test "patch takes path and edits[]":
    let act = toolCallToAction("qwen", "patch",
      %*{"path": "x.nim", "edits": [{"search": "a", "replace": "b"}]})
    check act.kind == akPatch
    check act.path == "x.nim"
    check act.edits == @[("a", "b")]

  test "gpt-oss tool name on glm rejected (training leak guard)":
    let act = toolCallToAction("glm", "shell", %*{"cmd": ["x"]})
    check act.kind == akBash
    check "tool not offered" in act.body
    check "glm/qwen" in act.body

suite "gpt-oss dispatch":
  test "shell takes argv as `cmd` — last element is the command line":
    # Captured live from nvidia.openai/gpt-oss-120b. Schema declares `cmd`,
    # model emits `cmd` — no aliases, no fallbacks.
    let act = toolCallToAction("gpt-oss", "shell",
                               %*{"cmd": ["bash", "-lc", "ls -R"]})
    check act.kind == akBash
    check act.body == "ls -R"

  test "shell with extra fields ignored":
    let act = toolCallToAction("gpt-oss", "shell",
      %*{"cmd": ["bash", "-lc", "git status"], "timeout": 10000})
    check act.kind == akBash
    check act.body == "git status"

  test "Harmony channel suffix on tool name is stripped":
    let act = toolCallToAction("gpt-oss", "shell<|channel|>commentary",
                               %*{"cmd": ["bash", "-lc", "uname -a"]})
    check act.kind == akBash
    check act.body == "uname -a"

  test "apply_patch carries V4A text in `input`":
    let v4a = "*** Begin Patch\n*** Update File: foo.txt\n@@\n-old\n+new\n*** End Patch"
    let act = toolCallToAction("gpt-oss", "apply_patch", %*{"input": v4a})
    check act.kind == akApplyPatch
    check act.body == v4a

  test "glm tool name on gpt-oss rejected (training leak guard)":
    let act = toolCallToAction("gpt-oss", "patch",
                               %*{"path": "x", "edits": []})
    check act.kind == akBash
    check "tool not offered" in act.body
    check "gpt-oss" in act.body

suite "dispatcher survives malformed args (regression net)":
  # The first ship of `shell` SIGSEGV'd because it called `.kind` on a
  # missing-key result (nil). Lock that whole class out: every model ×
  # every dispatchable name × empty args / null-ish / wrong-type must
  # produce a valid Action without crashing.
  for model in ["glm", "qwen", "gpt-oss"]:
    for name in ["bash", "shell", "write", "patch", "apply_patch", "unknown"]:
      test model & " " & name & ": empty args":
        discard toolCallToAction(model, name, newJObject())
      test model & " " & name & ": explicit nulls":
        discard toolCallToAction(model, name,
          %*{"command": nil, "cmd": nil, "path": nil, "body": nil,
             "edits": nil, "input": nil, "stdin": nil})
      test model & " " & name & ": wrong types":
        discard toolCallToAction(model, name,
          %*{"command": 42, "cmd": "not-an-array", "path": [1, 2],
             "body": {"oops": 1}, "edits": "string",
             "input": [1, 2], "stdin": []})
