import std/[json, os, strutils, unittest]
import threecode/[prompts, types]

suite "prompt cache stability":
  var root, cwd, configHome, dataHome: string
  var wasExperimental: bool
  var p: Profile
  var messages: JsonNode
  var state: PromptState

  setup:
    root = getTempDir() / ("3code-prompt-cache-" & $getCurrentProcessId())
    cwd = getCurrentDir()
    configHome = getEnv("XDG_CONFIG_HOME")
    dataHome = getEnv("XDG_DATA_HOME")
    wasExperimental = experimentalEnabled
    createDir(root / ".3code" / "skills")
    setCurrentDir(root)
    putEnv("XDG_CONFIG_HOME", root / "config")
    putEnv("XDG_DATA_HOME", root / "data")
    experimentalEnabled = true
    writeFile(root / ".3code" / "glm.txt", "Original {{credit}}\n{{skills}}")
    writeFile(root / ".3code" / "skills" / "first.md", "FIRST SKILL CONTENT")
    p = Profile(name: "zai.glm", model: "glm-5.3", family: "glm", version: "5", variant: "3")
    messages = %*[{"role": "system", "content": DefaultSystemPrompt},
                  {"role": "user", "content": "start"}]
    state = PromptState()

  teardown:
    setCurrentDir(cwd)
    putEnv("XDG_CONFIG_HOME", configHome)
    putEnv("XDG_DATA_HOME", dataHome)
    experimentalEnabled = wasExperimental
    removeDir(root)

  test "skill discovery and override edits leave the sent prefix unchanged":
    refreshSystemPrompt(messages, p, state)
    let prefix = $messages
    check "first.md" in messages[0]["content"].getStr
    check "FIRST SKILL CONTENT" notin $messages
    writeFile(root / ".3code" / "skills" / "second.md", "SECOND SKILL CONTENT")
    writeFile(root / ".3code" / "glm.txt", "Edited {{skills}}")
    messages.add %*{"role": "user", "content": "continue"}
    refreshSystemPrompt(messages, p, state)
    check $(%*[messages[0], messages[1]]) == prefix
    check messages[^1]["content"].getStr.startsWith("continue")
    check "second.md" in messages[^1]["content"].getStr
    check "SECOND SKILL CONTENT" notin $messages
    let after = $messages
    refreshSystemPrompt(messages, p, state)
    check $messages == after

  test "skill removal updates the catalog at the tail, not history":
    refreshSystemPrompt(messages, p, state)
    let system = messages[0]["content"].getStr
    removeFile(root / ".3code" / "skills" / "first.md")
    messages.add %*{"role": "user", "content": "continue"}
    refreshSystemPrompt(messages, p, state)
    check messages[0]["content"].getStr == system
    check "(none installed)" in messages[^1]["content"].getStr

  test "reasoning changes preserve the prefix, model changes refresh it":
    refreshSystemPrompt(messages, p, state)
    let system = messages[0]["content"].getStr
    p.reasoning = "high"
    refreshSystemPrompt(messages, p, state)
    check messages[0]["content"].getStr == system
    p.model = "glm-5.2"
    p.variant = "2"
    refreshSystemPrompt(messages, p, state)
    check "glm-5.2" in messages[0]["content"].getStr

  test "unchanged catalog never modifies history, even after a skill body edit":
    refreshSystemPrompt(messages, p, state)
    let before = $messages
    writeFile(root / ".3code" / "skills" / "first.md", "UPDATED BODY")
    refreshSystemPrompt(messages, p, state)
    check $messages == before

  test "compaction retaining the system node does not reload overrides":
    refreshSystemPrompt(messages, p, state)
    let system = messages[0]["content"].getStr
    writeFile(root / ".3code" / "glm.txt", "Edited {{skills}}")
    messages = %*[messages[0], {"role": "user", "content": "summary"}]
    refreshSystemPrompt(messages, p, state)
    check messages[0]["content"].getStr == system

  test "a new conversation picks up the edited prompt and current catalog":
    refreshSystemPrompt(messages, p, state)
    writeFile(root / ".3code" / "glm.txt", "Edited {{skills}}")
    messages = %*[{"role": "system", "content": DefaultSystemPrompt},
                  {"role": "user", "content": "new session"}]
    refreshSystemPrompt(messages, p, state)
    check messages[0]["content"].getStr.startsWith("Edited")

  test "resume rebuilds the prefix substituting the persisted catalog":
    # A saved session restores identity + the catalog its prompt was built
    # with; refresh reconstructs the prompt from the profile using those
    # exact bytes. A drifted catalog rides the tail, prefix untouched.
    state = PromptState(identity: profileIdentity(p),
                        skills: "- /old/solo.md")
    messages = %*[{"role": "system", "content": DefaultSystemPrompt},
                  {"role": "user", "content": "continue"}]
    refreshSystemPrompt(messages, p, state)
    let prefix = $messages[0]
    check "- /old/solo.md" in messages[0]["content"].getStr
    check "first.md" notin messages[0]["content"].getStr
    check messages[^1]["content"].getStr.startsWith("continue")
    check "first.md" in messages[^1]["content"].getStr
    refreshSystemPrompt(messages, p, state)
    check $messages[0] == prefix

  test "resume with a changed identity rebuilds from the current catalog":
    state = PromptState(identity: "[\"other\"]", skills: "- /old/solo.md")
    messages = %*[{"role": "system", "content": DefaultSystemPrompt},
                  {"role": "user", "content": "continue"}]
    refreshSystemPrompt(messages, p, state)
    check "first.md" in messages[0]["content"].getStr
    check "first.md" notin messages[^1]["content"].getStr

  test "resume picks up override edits (the prompt is constructed)":
    refreshSystemPrompt(messages, p, state)
    writeFile(root / ".3code" / "glm.txt", "Edited {{skills}}")
    state.system = nil   # resume shape: stamps restored, prompt rebuilt
    refreshSystemPrompt(messages, p, state)
    check messages[0]["content"].getStr.startsWith("Edited")

  test "resume without a persisted catalog builds from the current one":
    # Legacy sessions saved before the skills record: no catalog bytes to
    # substitute, so the rebuild uses the live discovery.
    state = PromptState(identity: profileIdentity(p), skills: "")
    messages = %*[{"role": "system", "content": DefaultSystemPrompt},
                  {"role": "user", "content": "continue"}]
    refreshSystemPrompt(messages, p, state)
    check "first.md" in messages[0]["content"].getStr
    check "first.md" notin messages[^1]["content"].getStr
