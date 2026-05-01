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

  test "shell aliases to bash (gpt-oss training leak, argv shape)":
    let act = toolCallToAction("glm", "shell",
                               %*{"cmd": ["bash", "-lc", "ls -R"]})
    check act.kind == akBash
    check act.body == "ls -R"

  test "apply_patch aliases to akApplyPatch on glm/qwen":
    let v4a = "*** Begin Patch\n*** Add File: x.txt\n+hi\n*** End Patch"
    let act = toolCallToAction("qwen", "apply_patch", %*{"input": v4a})
    check act.kind == akApplyPatch
    check act.body == v4a

  test "applypatch / apply-patch misspellings alias on glm too":
    let v4a = "*** Begin Patch\n*** Add File: x\n+hi\n*** End Patch"
    let a1 = toolCallToAction("glm", "applypatch", %*{"input": v4a})
    let a2 = toolCallToAction("glm", "apply-patch", %*{"input": v4a})
    check a1.kind == akApplyPatch
    check a2.kind == akApplyPatch

  test "edit aliases to akPatch on glm/qwen":
    let act = toolCallToAction("qwen", "edit",
      %*{"path": "x.nim", "edits": [{"search": "a", "replace": "b"}]})
    check act.kind == akPatch
    check act.path == "x.nim"
    check act.edits == @[("a", "b")]

suite "gpt-oss dispatch":
  test "shell takes argv as `cmd` — last element is the command line":
    # Captured live from nvidia.openai/gpt-oss-120b. Canonical name
    # for the schema we offer gpt-oss.
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

  test "bash aliases to akBash (qwen-shape training leak)":
    let act = toolCallToAction("gpt-oss", "bash",
                               %*{"command": "uname -a"})
    check act.kind == akBash
    check act.body == "uname -a"

  test "bash also accepts argv-shape on gpt-oss":
    let act = toolCallToAction("gpt-oss", "bash",
                               %*{"cmd": ["bash", "-lc", "ls"]})
    check act.kind == akBash
    check act.body == "ls"

  test "write aliases to akWrite on gpt-oss":
    let act = toolCallToAction("gpt-oss", "write",
                               %*{"path": "x.nim", "body": "echo 1"})
    check act.kind == akWrite
    check act.path == "x.nim"
    check act.body == "echo 1"

  test "patch aliases to akPatch on gpt-oss (no longer rejected)":
    let act = toolCallToAction("gpt-oss", "patch",
      %*{"path": "x.nim", "edits": [{"search": "a", "replace": "b"}]})
    check act.kind == akPatch
    check act.path == "x.nim"
    check act.edits == @[("a", "b")]

  test "edit aliases to akPatch on gpt-oss":
    let act = toolCallToAction("gpt-oss", "edit",
      %*{"path": "x.nim", "edits": [{"search": "a", "replace": "b"}]})
    check act.kind == akPatch

  test "applypatch / apply-patch misspellings alias on gpt-oss":
    let v4a = "*** Begin Patch\n*** Add File: x\n+hi\n*** End Patch"
    let a1 = toolCallToAction("gpt-oss", "applypatch", %*{"input": v4a})
    let a2 = toolCallToAction("gpt-oss", "apply-patch", %*{"input": v4a})
    check a1.kind == akApplyPatch
    check a2.kind == akApplyPatch

  test "truly unknown tool falls through to akError":
    let act = toolCallToAction("gpt-oss", "browse_web", %*{})
    check act.kind == akError
    check act.path == "browse_web"
    check "is not available" in act.body

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
