import std/[unittest, json]
import threecode/[types, actions]

suite "gptoss JSON syntax":
  test "cmd array: last element is the command":
    let act = toolCallToAction("bash", %*{"cmd": ["bash", "-lc", "ls -R"]})
    check act.kind == akBash
    check act.body == "ls -R"

  test "cmd array with extra fields ignored":
    let act = toolCallToAction("bash", %*{"cmd": ["bash", "-lc", "git status"], "timeout": 10000})
    check act.kind == akBash
    check act.body == "git status"

  test "standard command key still works":
    let act = toolCallToAction("bash", %*{"command": "nimble test"})
    check act.kind == akBash
    check act.body == "nimble test"

  test "channel suffix stripped from name":
    check normalizeToolName("bash<|channel|>analysis") == "bash"
    check normalizeToolName("bash<|channel|>json") == "bash"
    check normalizeToolName("bash") == "bash"
    check normalizeToolName("patch") == "patch"
    check normalizeToolName("write<|channel|>output") == "write"

  test "normalized name dispatches to correct action":
    let act = toolCallToAction(normalizeToolName("bash<|channel|>analysis"), %*{"command": "ls"})
    check act.kind == akBash
    check act.body == "ls"

  test "cmd array with normalized name":
    let act = toolCallToAction(normalizeToolName("bash<|channel|>json"), %*{"cmd": ["bash", "-lc", "cat foo.nimble"]})
    check act.kind == akBash
    check act.body == "cat foo.nimble"
