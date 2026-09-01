import std/[algorithm, json, monotimes, os, sequtils, strutils, times, unittest]
import threecode/[api, auth_openai, config, minline, types, ui]

proc stripAnsiCsi(line: string): string =
  var i = 0
  while i < line.len:
    if line[i] == '\e' and i + 1 < line.len and line[i + 1] == '[':
      i += 2
      while i < line.len and line[i] notin {'@'..'~'}:
        inc i
      if i < line.len:
        inc i
    else:
      result.add line[i]
      inc i

proc nvidiaModels(): seq[string] =
  @[
    "z-ai/glm-5.2",
    "openai/gpt-oss-120b",
    "openai/gpt-oss-20b",
    "minimaxai/minimax-m2.5",
    "minimaxai/minimax-m2.7",
  ]

suite "provider wizard configuration":
  var
    savedCurrent: string
    savedProviders: seq[ProviderRec]
    savedExperimental: bool
    savedXdg: string
    hadXdg: bool
    tempConfig: string
    inputs: seq[string]
    prompts: seq[string]
    verifiedModels: seq[string]

  setup:
    savedCurrent = activeCurrent
    savedProviders = activeProviders
    savedExperimental = experimentalEnabled
    hadXdg = existsEnv("XDG_CONFIG_HOME")
    savedXdg = getEnv("XDG_CONFIG_HOME")
    tempConfig = getTempDir() / ("3code-provider-wizard-" &
      $getCurrentProcessId())
    putEnv("XDG_CONFIG_HOME", tempConfig)
    activeCurrent = ""
    activeProviders = @[]
    experimentalEnabled = false
    inputs = @[]
    prompts = @[]
    verifiedModels = @[]
    wizardReadLineHook = proc(prompt: string, hidden, noHistory: bool): string =
      prompts.add prompt
      if inputs.len == 0:
        raise newException(AssertionDefect, "missing wizard input for " & prompt)
      result = inputs[0]
      inputs.delete(0)
    verifyProfileHook = proc(p: Profile): (bool, string) =
      check prompts.anyIt(it.startsWith("  models ["))
      verifiedModels.add p.model
      (true, "")
    fetchModelsHook = proc(url, key: string): (seq[string], string) =
      (nvidiaModels(), "")

  teardown:
    wizardReadLineHook = nil
    wizardVerifyCancelHook = nil
    verifyProfileHook = nil
    fetchModelsHook = nil
    activeCurrent = savedCurrent
    activeProviders = savedProviders
    experimentalEnabled = savedExperimental
    if hadXdg:
      putEnv("XDG_CONFIG_HOME", savedXdg)
    else:
      delEnv("XDG_CONFIG_HOME")
    try: removeDir(tempConfig / "3code")
    except OSError: discard
    try: removeDir(tempConfig)
    except OSError: discard

  test "initial bootstrap saves without a verification ping":
    inputs = @["nvapi-initial", "gpt-oss-120b"]
    var editor: LineEditor

    let prof = bootstrapProvider(editor)

    check prof.name == "nvidia.openai/gpt-oss-120b"
    check activeProviders.len == 1
    check activeProviders[0].models == @["openai/gpt-oss-120b"]
    check verifiedModels.len == 0

  test "additional add prompts for model before verifying detected provider":
    activeProviders = @[
      ProviderRec(name: "groq", url: "https://api.groq.com/openai/v1",
                  key: "gsk-existing", models: @["openai/gpt-oss-20b"])
    ]
    activeCurrent = "groq.openai/gpt-oss-20b"
    inputs = @["nvapi-add", "gpt-oss-20b"]
    var editor: LineEditor
    var prof = buildProfile(activeCurrent, activeProviders, "")
    var messages = newJArray()
    var session = Session()

    discard handleCommand(":provider add", messages, session, prof, editor)

    check activeProviders.len == 2
    check activeProviders[1].name == "nvidia"
    check activeProviders[1].models == @["openai/gpt-oss-20b"]
    check activeCurrent == "groq.openai/gpt-oss-20b"
    check verifiedModels.len == 0

  test "add accepts provider name then api key":
    inputs = @["nvidia", "nvapi-named", "gpt-oss-120b"]
    var editor: LineEditor
    var prof: Profile
    var messages = newJArray()
    var session = Session()

    discard handleCommand(":provider add", messages, session, prof, editor)

    check activeProviders.len == 1
    check activeProviders[0].name == "nvidia"
    check activeProviders[0].key == "nvapi-named"
    check activeProviders[0].models == @["openai/gpt-oss-120b"]
    check prompts.anyIt(it.startsWith("  provider, url, or api key:"))
    check prompts.anyIt(it.startsWith("  api key"))

  test "add rejects duplicate provider name":
    activeProviders = @[
      ProviderRec(name: "nvidia", url: "https://integrate.api.nvidia.com/v1",
                  key: "nvapi-existing", models: @["openai/gpt-oss-120b"])
    ]
    activeCurrent = "nvidia.openai/gpt-oss-120b"
    inputs = @["nvapi-add", "gpt-oss-20b"]
    var editor: LineEditor
    var prof = buildProfile(activeCurrent, activeProviders, "")
    var messages = newJArray()
    var session = Session()

    discard handleCommand(":provider add", messages, session, prof, editor)

    check activeProviders.len == 1
    check activeProviders[0].name == "nvidia"
    check activeCurrent == "nvidia.openai/gpt-oss-120b"

  test "edit fetches chatgpt models from the codex backend":
    # The chatgpt OAuth token 403s on api.openai.com/v1/models
    # (api.model.read); the wizard must list via the Codex backend hook.
    # Regular mode never calls /models (curated list only), so this runs
    # under --experimental where the endpoint is consulted.
    experimentalEnabled = true
    activeProviders = @[
      ProviderRec(name: "chatgpt", url: "https://api.openai.com/v1",
                  auth: "oauth", models: @["gpt-5.4"])
    ]
    activeCurrent = "chatgpt.gpt-5.4"
    var fetchedUrls: seq[string]
    fetchModelsHook = proc(url, key: string): (seq[string], string) =
      fetchedUrls.add url
      if url == auth_openai.CodexApiUrl:
        (@["gpt-5.4", "gpt-5.5"], "")
      else:
        (@[], "HTTP 403")
    inputs = @["", "", "", "gpt-5.5"]
    var editor: LineEditor
    var prof = buildProfile(activeCurrent, activeProviders, "")
    var messages = newJArray()
    var session = Session()

    discard handleCommand(":provider edit chatgpt", messages, session, prof,
                          editor)

    check fetchedUrls == @[auth_openai.CodexApiUrl]
    check activeProviders[0].models == @["gpt-5.5"]
    check verifiedModels == @["gpt-5.5"]

  test "edit prompts for model before verifying updated provider":
    activeProviders = @[
      ProviderRec(name: "nvidia", url: "https://integrate.api.nvidia.com/v1",
                  key: "nvapi-old", models: @["z-ai/glm-5.2"])
    ]
    activeCurrent = "nvidia.z-ai/glm-5.2"
    inputs = @["", "", "gpt-oss-120b"]
    var editor: LineEditor
    var prof = buildProfile(activeCurrent, activeProviders, "")
    var messages = newJArray()
    var session = Session()

    discard handleCommand(":provider edit nvidia", messages, session, prof,
                          editor)

    check activeProviders.len == 1
    check activeProviders[0].models == @["openai/gpt-oss-120b"]
    check activeCurrent == "nvidia.openai/gpt-oss-120b"
    check verifiedModels.len == 0

  test "add prefers known-good id over listed-but-unserved variant":
    # kimicode's /models listed kimi-k3 and kimi-k3-256k, but the
    # endpoint only serves `k3`; the -256k id passed the verification
    # ping and 401'd on the first real turn. The wizard rewrites the
    # listed variant to the known-good id before saving.
    experimentalEnabled = true
    fetchModelsHook = proc(url, key: string): (seq[string], string) =
      (@["kimi-k3", "kimi-k3-256k"], "")
    inputs = @["", "sk-kimi", "kimi-k3-256k"]
    verifyProfileHook = proc(p: Profile): (bool, string) =
      verifiedModels.add p.model
      (true, "")
    var editor: LineEditor
    var prof: Profile
    var messages = newJArray()
    var session = Session()

    discard handleCommand(":provider add kimicode", messages, session, prof,
                          editor)

    check activeProviders.len == 1
    check activeProviders[0].models == @["k3"]
    check verifiedModels == @["k3"]

  test "add verifies every entered model and keeps only the ones that pass":
    # Experimental mode still verifies; a failed model is a warning, not
    # a blocker: the provider is saved with the models that verified.
    experimentalEnabled = true
    inputs = @["nvapi-add", "gpt-oss-120b gpt-oss-20b"]
    verifyProfileHook = proc(p: Profile): (bool, string) =
      verifiedModels.add p.model
      if p.model == "openai/gpt-oss-20b": (false, "HTTP 404")
      else: (true, "")
    var editor: LineEditor
    var prof: Profile
    var messages = newJArray()
    var session = Session()

    discard handleCommand(":provider add", messages, session, prof, editor)

    check activeProviders.len == 1
    check activeProviders[0].models == @["openai/gpt-oss-120b"]
    check verifiedModels == @["openai/gpt-oss-120b", "openai/gpt-oss-20b"]

  test "add re-prompts when every model fails verification":
    experimentalEnabled = true
    inputs = @["nvapi-add", "gpt-oss-120b", "", "gpt-oss-120b"]
    var attempts = 0
    verifyProfileHook = proc(p: Profile): (bool, string) =
      verifiedModels.add p.model
      inc attempts
      if attempts == 1: (false, "HTTP 401")
      else: (true, "")
    var editor: LineEditor
    var prof: Profile
    var messages = newJArray()
    var session = Session()

    discard handleCommand(":provider add", messages, session, prof, editor)

    check activeProviders.len == 1
    check attempts == 2

  test "edit verifies every entered model and keeps only the ones that pass":
    experimentalEnabled = true
    activeProviders = @[
      ProviderRec(name: "nvidia", url: "https://integrate.api.nvidia.com/v1",
                  key: "nvapi-old", models: @["z-ai/glm-5.2"])
    ]
    activeCurrent = "nvidia.z-ai/glm-5.2"
    inputs = @["", "", "", "gpt-oss-120b gpt-oss-20b"]
    verifyProfileHook = proc(p: Profile): (bool, string) =
      verifiedModels.add p.model
      if p.model == "openai/gpt-oss-20b": (false, "HTTP 404")
      else: (true, "")
    var editor: LineEditor
    var prof = buildProfile(activeCurrent, activeProviders, "")
    var messages = newJArray()
    var session = Session()

    discard handleCommand(":provider edit nvidia", messages, session, prof,
                          editor)

    check activeProviders[0].models == @["openai/gpt-oss-120b"]
    check activeCurrent == "nvidia.openai/gpt-oss-120b"

  test "verification cancel hook aborts the add":
    experimentalEnabled = true
    inputs = @["nvapi-add", "gpt-oss-120b"]
    wizardVerifyCancelHook = proc(jobDone: proc(): bool {.closure.};
                                  cancelJob: proc() {.closure.}): bool =
      check not jobDone()
      cancelJob()
      true
    verifyProfileHook = proc(p: Profile): (bool, string) =
      (true, "")
    var editor: LineEditor
    var prof: Profile
    var messages = newJArray()
    var session = Session()

    discard handleCommand(":provider add", messages, session, prof, editor)

    check activeProviders.len == 0

  test "verification workers run in parallel":
    # Two slow probes, each ~400ms: sequential would take ~800ms,
    # parallel lands well under that. Uses the threaded path (cancel
    # hook installed) since that is where parallelism matters.
    experimentalEnabled = true
    inputs = @["nvapi-add", "gpt-oss-120b gpt-oss-20b"]
    wizardVerifyCancelHook = proc(jobDone: proc(): bool {.closure.};
                                  cancelJob: proc() {.closure.}): bool =
      while not jobDone(): sleep 5
      false
    verifyProfileHook = proc(p: Profile): (bool, string) =
      sleep 400
      (true, "")
    var editor: LineEditor
    var prof: Profile
    var messages = newJArray()
    var session = Session()

    let t0 = getMonoTime()
    discard handleCommand(":provider add", messages, session, prof, editor)
    let elapsed = (getMonoTime() - t0).inMilliseconds

    check activeProviders.len == 1
    check activeProviders[0].models == @["openai/gpt-oss-120b",
                                         "openai/gpt-oss-20b"]
    check elapsed < 700

  test "add wizard lists models sorted alphabetically":
    activeProviders = @[
      ProviderRec(name: "groq", url: "https://api.groq.com/openai/v1",
                  key: "gsk-existing", models: @["openai/gpt-oss-20b"])
    ]
    activeCurrent = "groq.openai/gpt-oss-20b"
    inputs = @["nvapi-add", "gpt-oss-120b"]
    var editor: LineEditor
    var prof = buildProfile(activeCurrent, activeProviders, "")
    var messages = newJArray()
    var session = Session()

  # These two tests capture wizard stdout to a temp file by reassigning
  # the `stdout` global var. On Windows MinGW, `stdout` is a macro
  # (`(&__iob_func()[1])`), so the generated C assignment `stdout = f`
  # fails to compile with `error: lvalue required as left operand of
  # assignment`. The other 7 subtests in this file don't use stdout
  # capture and run unchanged on Windows. See docs/windows-testing.md.
  when not defined(windows):
    test "add wizard lists models sorted alphabetically":
      activeProviders = @[
        ProviderRec(name: "groq", url: "https://api.groq.com/openai/v1",
                    key: "gsk-existing", models: @["openai/gpt-oss-20b"])
      ]
      activeCurrent = "groq.openai/gpt-oss-20b"
      experimentalEnabled = true
      inputs = @["nvapi-add", "gpt-oss-120b"]
      var editor: LineEditor
      var prof = buildProfile(activeCurrent, activeProviders, "")
      var messages = newJArray()
      var session = Session()

      # Capture stdout to verify model listing order. The wizard writes
      # directly to stdout via hintLn, so we swap the `stdout` var for a
      # temp file around the call. The earlier posix.dup/dup2 trick
      # only redirected the OS fd, which the C runtime ignores on Windows
      # (it writes to the buffered FILE*'s own HANDLE, not fd 1).
      let capturePath = getTempDir() / "wizard_add_capture.txt"
      let savedStdout = stdout
      let captureFile = open(capturePath, fmWrite)
      stdout = captureFile
      try:
        discard handleCommand(":provider add", messages, session, prof, editor)
      finally:
        flushFile(stdout)
        stdout = savedStdout
        close(captureFile)
      let capturedOutput = readFile(capturePath)
      try: removeFile(capturePath) except OSError: discard

      # The models should be listed in sorted order.
      # The nvidiaModels() stub returns them jumbled; the wizard must sort.
      # Extract the short model names in the order they appear in the output.
      var listedModels: seq[string]
      for line in capturedOutput.splitLines:
        let stripped = stripAnsiCsi(line.strip)
        # Model lines start with "    " (4 spaces) and contain a model name
        if stripped.len > 4 and stripped[0..3] == "    " and
           stripped[4..^1].shortModel() != "" and
           stripped[4..^1] != "5 available" and
           stripped[4..^1] != "verifying..." and
           stripped[4..^1] != "ok" and
           stripped[4..^1] != "added nvidia" and
           stripped[4..^1] != "detected: nvidia -> https://integrate.api.nvidia.com/v1":
          listedModels.add stripped[4..^1].shortModel()
      check listedModels == @["minimax-m2.5", "minimax-m2.7", "gpt-oss-120b",
                             "gpt-oss-20b", "glm-5.2"]

  test "wizard inputs are not added to history":
    # Bug 2: wizard inputs must not pollute history. readRequired/readOptional
    # default to noHistory = true, so the wizard's readLine calls must pass
    # noHistory = true. We verify by checking the hook receives noHistory = true.
    var historyFlags: seq[bool]
    wizardReadLineHook = proc(prompt: string, hidden, noHistory: bool): string =
      historyFlags.add noHistory
      if inputs.len == 0:
        raise newException(AssertionDefect, "missing wizard input for " & prompt)
      result = inputs[0]
      inputs.delete(0)
    activeProviders = @[
      ProviderRec(name: "nvidia", url: "https://integrate.api.nvidia.com/v1",
                  key: "nvapi-existing", models: @["openai/gpt-oss-120b"])
    ]
    activeCurrent = "nvidia.openai/gpt-oss-120b"
    inputs = @["nvapi-add", "gpt-oss-20b"]
    var editor: LineEditor
    var prof = buildProfile(activeCurrent, activeProviders, "")
    var messages = newJArray()
    var session = Session()

    discard handleCommand(":provider add", messages, session, prof, editor)

    # Every wizard input must have been called with noHistory = true
    check historyFlags.len > 0
    for flag in historyFlags:
      check flag == true

  test "wizard model prompt has tab completion":
    # Bug 3: tab completion must be available for model entry. The wizard
    # sets editor.completionCallback to return available models. We verify
    # the callback is set during the wizard and returns model names.
    # Use a fresh provider (groq) so the wizard doesn't return early.
    var callbackWasSet = false
    var capturedModels: seq[string]
    activeProviders = @[
      ProviderRec(name: "groq", url: "https://api.groq.com/openai/v1",
                  key: "gsk-existing", models: @["openai/gpt-oss-20b"])
    ]
    activeCurrent = "groq.openai/gpt-oss-20b"
    experimentalEnabled = true
    inputs = @["nvapi-add", "gpt-oss-120b"]
    var editor: LineEditor
    var prof = buildProfile(activeCurrent, activeProviders, "")
    var messages = newJArray()
    var session = Session()

    # Wrap the wizardReadLineHook to capture editor state
    wizardReadLineHook = proc(prompt: string, hidden, noHistory: bool): string =
      prompts.add prompt
      # Capture the callback whenever it's set (non-nil)
      if editor.completionCallback != nil:
        callbackWasSet = true
        capturedModels = editor.completionCallback(editor)
      if inputs.len == 0:
        raise newException(AssertionDefect, "missing wizard input for " & prompt)
      result = inputs[0]
      inputs.delete(0)

    discard handleCommand(":provider add", messages, session, prof, editor)

    # The completion callback must have been set during the wizard
    check callbackWasSet
    # The callback should return model names
    check capturedModels.len > 0
    check "gpt-oss-120b" in capturedModels

  when not defined(windows):
    test "edit wizard lists curated models, no /models fetch":
      activeProviders = @[
        ProviderRec(name: "nvidia", url: "https://integrate.api.nvidia.com/v1",
                    key: "nvapi-old", models: @["z-ai/glm-5.2"])
      ]
      activeCurrent = "nvidia.z-ai/glm-5.2"
      inputs = @["", "", "gpt-oss-120b"]
      var fetchCount = 0
      fetchModelsHook = proc(url, key: string): (seq[string], string) =
        inc fetchCount
        (nvidiaModels(), "")
      var editor: LineEditor
      var prof = buildProfile(activeCurrent, activeProviders, "")
      var messages = newJArray()
      var session = Session()

      # Capture stdout to verify model listing order. See the add-wizard
      # test above for why we swap the `stdout` var.
      let capturePath = getTempDir() / "wizard_edit_capture.txt"
      let savedStdout = stdout
      let captureFile = open(capturePath, fmWrite)
      stdout = captureFile
      try:
        discard handleCommand(":provider edit nvidia", messages, session, prof,
                              editor)
      finally:
        flushFile(stdout)
        stdout = savedStdout
        close(captureFile)
      let capturedOutput = readFile(capturePath)
      try: removeFile(capturePath) except OSError: discard

      # Regular mode lists the curated known-good models (KnownGoodCombos
      # order), not the endpoint's /models payload.
      var listedModels: seq[string]
      for line in capturedOutput.splitLines:
        let stripped = stripAnsiCsi(line.strip)
        # Model lines start with "    " (4 spaces) and contain a model name
        if stripped.len > 4 and stripped[0..3] == "    " and
           stripped[4..^1].shortModel() != "" and
           stripped[4..^1] != "8 available" and
           stripped[4..^1] != "verifying..." and
           stripped[4..^1] != "ok" and
           stripped[4..^1] != "updated nvidia" and
           stripped[4..^1] != "editing 'nvidia' (enter to keep, ctrl+c to abort)":
          listedModels.add stripped[4..^1].shortModel()
      check listedModels == curatedFor("nvidia").mapIt(shortModel(it))
      check fetchCount == 0

    test "edit wizard experimental: full /models endpoint output is offered":
      # In experimental mode the wizard fetches /models and offers the
      # full endpoint output, including ids not in the known-good
      # registry (minimax-m2.5/m2.7). Non-experimental mode is the one
      # that restricts to the curated list.
      experimentalEnabled = true
      activeProviders = @[
        ProviderRec(name: "nvidia", url: "https://integrate.api.nvidia.com/v1",
                    key: "nvapi-old", models: @["z-ai/glm-5.2"])
      ]
      activeCurrent = "nvidia.z-ai/glm-5.2"
      inputs = @["", "", "", "gpt-oss-120b"]
      var fetchCount = 0
      fetchModelsHook = proc(url, key: string): (seq[string], string) =
        inc fetchCount
        (nvidiaModels(), "")
      var editor: LineEditor
      var prof = buildProfile(activeCurrent, activeProviders, "")
      var messages = newJArray()
      var session = Session()

      let capturePath = getTempDir() / "wizard_edit_exp_capture.txt"
      let savedStdout = stdout
      let captureFile = open(capturePath, fmWrite)
      stdout = captureFile
      try:
        discard handleCommand(":provider edit nvidia", messages, session, prof,
                              editor)
      finally:
        flushFile(stdout)
        stdout = savedStdout
        close(captureFile)
      let capturedOutput = readFile(capturePath)
      try: removeFile(capturePath) except OSError: discard

      check fetchCount == 1
      var listedModels: seq[string]
      for line in capturedOutput.splitLines:
        let stripped = stripAnsiCsi(line.strip)
        if stripped.len > 4 and stripped[0..3] == "    " and
           stripped[4..^1].shortModel() != "" and
           not stripped[4..^1].endsWith(" available") and
           stripped[4..^1] != "verifying..." and
           stripped[4..^1] != "ok" and
           stripped[4..^1] != "updated nvidia" and
           not stripped.startsWith("editing '"):
          listedModels.add stripped[4..^1].shortModel()
      # nvidiaModels() (the stub endpoint list) carries glm-5.2, the two
      # gpt-oss ids and the two minimax ids. Experimental mode offers the
      # full endpoint output, so minimax-m2.5/m2.7 (not in the nvidia
      # KnownGoodCombos registry) must be listed.
      let expected = nvidiaModels().sorted
      check listedModels == expected.mapIt(shortModel(it))
      check "minimax-m2.5" in listedModels
      check "minimax-m2.7" in listedModels
