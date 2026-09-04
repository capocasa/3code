import std/[algorithm, atomics, json, os, sequtils, strutils, times, unittest]
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
    check prompts.anyIt(it.startsWith("  provider or api key:"))
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
    # The verify hook blocks until the cancel flag is set: without that,
    # an instant-verify worker can finish before the cancel hook's first
    # jobDone() poll under load, and `check not jobDone()` races the
    # scheduler instead of testing the cancel path.
    type Flag = object
      f: Atomic[bool]
    let cancelledFlag = cast[ptr Flag](allocShared0(sizeof(Flag)))
    defer: deallocShared(cancelledFlag)
    wizardVerifyCancelHook = proc(jobDone: proc(): bool {.closure.};
                                  cancelJob: proc() {.closure.}): bool =
      check not jobDone()
      cancelJob()
      {.cast(gcsafe).}:
        cancelledFlag.f.store(true, moRelease)
      true
    verifyProfileHook = proc(p: Profile): (bool, string) =
      {.cast(gcsafe).}:
        while not cancelledFlag.f.load(moAcquire):
          sleep 1
      (true, "")
    var editor: LineEditor
    var prof: Profile
    var messages = newJArray()
    var session = Session()

    discard handleCommand(":provider add", messages, session, prof, editor)

    check activeProviders.len == 0

  test "verification workers run in parallel":
    # Overlap is proven by rendezvous, not by a wall-clock bound: each
    # worker blocks until BOTH workers are inside verifyProfileHook.
    # Sequential execution deadlocks worker 1 waiting for worker 2, which
    # fails the run loudly (a stuck thread plus an eventual suite timeout)
    # instead of racing a `elapsed < 700` check under parallel-suite load.
    # Uses the threaded path (cancel hook installed) since that is where
    # parallelism matters.
    experimentalEnabled = true
    inputs = @["nvapi-add", "gpt-oss-120b gpt-oss-20b"]
    type Rendezvous = object
      entered: Atomic[int]
      bothIn: Atomic[bool]
    let rdv = cast[ptr Rendezvous](allocShared0(sizeof(Rendezvous)))
    defer: deallocShared(rdv)
    wizardVerifyCancelHook = proc(jobDone: proc(): bool {.closure.};
                                  cancelJob: proc() {.closure.}): bool =
      while not jobDone(): sleep 5
      false
    verifyProfileHook = proc(p: Profile): (bool, string) =
      {.cast(gcsafe).}:
        discard rdv.entered.fetchAdd(1, moAcquireRelease)
        while not rdv.bothIn.load(moAcquire):
          if rdv.entered.load(moAcquire) >= 2: break
          sleep 1
        rdv.bothIn.store(true, moRelease)
      (true, "")
    var editor: LineEditor
    var prof: Profile
    var messages = newJArray()
    var session = Session()

    discard handleCommand(":provider add", messages, session, prof, editor)

    check activeProviders.len == 1
    check activeProviders[0].models == @["openai/gpt-oss-120b",
                                         "openai/gpt-oss-20b"]
    check rdv.bothIn.load(moAcquire)

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
      let capturePath = getTempDir() / ("wizard_add_capture_" & $getCurrentProcessId() & ".txt")
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
      let capturePath = getTempDir() / ("wizard_edit_capture_" & $getCurrentProcessId() & ".txt")
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

      let capturePath = getTempDir() / ("wizard_edit_exp_capture_" & $getCurrentProcessId() & ".txt")
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

  test "add rejects a url in regular mode":
    # The label promises "provider or api key" without --experimental;
    # a pasted custom URL must be refused outright.
    inputs = @["https://api.example.com/v1"]
    var editor: LineEditor
    var prof: Profile
    var messages = newJArray()
    var session = Session()

    discard handleCommand(":provider add", messages, session, prof, editor)

    check activeProviders.len == 0

  test "add rejects an unrecognized api key in regular mode":
    inputs = @["some-free-text-secret"]
    var editor: LineEditor
    var prof: Profile
    var messages = newJArray()
    var session = Session()

    discard handleCommand(":provider add", messages, session, prof, editor)

    check activeProviders.len == 0

  test "add rejects a non-listed model in regular mode":
    # The unknown model re-prompts; the follow-up curated entry saves.
    inputs = @["nvapi-add", "totally-made-up-model", "gpt-oss-120b"]
    var editor: LineEditor
    var prof: Profile
    var messages = newJArray()
    var session = Session()

    discard handleCommand(":provider add", messages, session, prof, editor)

    check activeProviders.len == 1
    check activeProviders[0].models == @["openai/gpt-oss-120b"]
    check verifiedModels.len == 0

  test "add accepts a custom url with a custom name in experimental mode":
    experimentalEnabled = true
    verifyProfileHook = proc(p: Profile): (bool, string) =
      verifiedModels.add p.model
      (true, "")
    inputs = @["https://api.example.com/v1", "acme", "sk-acme", "acme-1"]
    var editor: LineEditor
    var prof: Profile
    var messages = newJArray()
    var session = Session()

    discard handleCommand(":provider add", messages, session, prof, editor)

    check activeProviders.len == 1
    check activeProviders[0].name == "acme"
    check activeProviders[0].url == "https://api.example.com/v1"
    check activeProviders[0].models == @["acme-1"]
    check verifiedModels == @["acme-1"]

  test "add accepts an unrecognized api key with a custom name in experimental mode":
    # The key prefix does not resolve, so the entry reads as a provider
    # name; experimental mode asks for the url and key explicitly.
    experimentalEnabled = true
    verifyProfileHook = proc(p: Profile): (bool, string) =
      verifiedModels.add p.model
      (true, "")
    inputs = @["acme2", "https://api2.example.com/v1", "weird-secret", "acme-2"]
    var editor: LineEditor
    var prof: Profile
    var messages = newJArray()
    var session = Session()

    discard handleCommand(":provider add", messages, session, prof, editor)

    check activeProviders.len == 1
    check activeProviders[0].name == "acme2"
    check activeProviders[0].url == "https://api2.example.com/v1"
    check activeProviders[0].models == @["acme-2"]
    check verifiedModels == @["acme-2"]

  test "add accepts a free-text model in experimental mode":
    experimentalEnabled = true
    inputs = @["nvapi-add", "totally-made-up-model"]
    var editor: LineEditor
    var prof: Profile
    var messages = newJArray()
    var session = Session()

    discard handleCommand(":provider add", messages, session, prof, editor)

    check activeProviders.len == 1
    check activeProviders[0].models == @["totally-made-up-model"]
    check verifiedModels == @["totally-made-up-model"]

  test "add prefilled with an api key never enters the wizard":
    # Regression: `:provider add <key>` prefills the first field; the
    # wizard must run the key-detection path directly, never surfacing
    # "unknown provider" for the key itself.
    var editor: LineEditor
    var prof: Profile
    var messages = newJArray()
    var session = Session()
    inputs = @["gpt-oss-120b"]

    discard handleCommand(":provider add nvapi-prefilled", messages, session,
                          prof, editor)

    check activeProviders.len == 1
    check activeProviders[0].name == "nvidia"
    check activeProviders[0].key == "nvapi-prefilled"
    check activeProviders[0].models == @["openai/gpt-oss-120b"]

  test "first field label matches the mode":
    # Regular mode takes a provider name or api key only; the label must
    # not promise URLs it will reject. Experimental mode takes all three.
    var editor: LineEditor
    var prof: Profile
    var messages = newJArray()
    var session = Session()

    experimentalEnabled = false
    inputs = @["nvapi-key", "gpt-oss-120b"]
    discard handleCommand(":provider add", messages, session, prof, editor)
    check prompts[0] == "  provider or api key: "

    prompts = @[]
    activeProviders = @[]
    activeCurrent = ""
    experimentalEnabled = true
    inputs = @["nvapi-key2", "gpt-oss-120b"]
    discard handleCommand(":provider add", messages, session, prof, editor)
    check prompts[0] == "  provider, url, or api key: "

  test "first field completion lists catalog names only in experimental mode":
    # The completed set is the same set the wizard accepts: known-good
    # names in regular mode, the full catalog under --experimental.
    var editor: LineEditor
    var firstFieldCompletions: seq[string]
    wizardReadLineHook = proc(prompt: string, hidden, noHistory: bool): string =
      if prompt.startsWith("  provider"):
        firstFieldCompletions = editor.completionCallback(editor)
      prompts.add prompt
      if inputs.len == 0:
        raise newException(AssertionDefect, "missing wizard input for " & prompt)
      result = inputs[0]
      inputs.delete(0)

    var prof: Profile
    var messages = newJArray()
    var session = Session()

    experimentalEnabled = false
    inputs = @["nvapi-key", "gpt-oss-120b"]
    discard handleCommand(":provider add", messages, session, prof, editor)
    check "nvidia" in firstFieldCompletions
    check "mistral" notin firstFieldCompletions

    activeProviders = @[]
    activeCurrent = ""
    firstFieldCompletions = @[]
    experimentalEnabled = true
    inputs = @["nvapi-key2", "gpt-oss-120b"]
    discard handleCommand(":provider add", messages, session, prof, editor)
    check "mistral" in firstFieldCompletions

  test "edit rejects a free-text model in regular mode":
    # Same rule as the add wizard: without --experimental the model list
    # is closed. The first bogus entry re-prompts the whole edit loop;
    # the second, curated, pass saves.
    activeProviders = @[
      ProviderRec(name: "nvidia", url: "https://integrate.api.nvidia.com/v1",
                  key: "nvapi-old", models: @["z-ai/glm-5.2"])
    ]
    activeCurrent = "nvidia.z-ai/glm-5.2"
    inputs = @["", "", "totally-made-up-model", "", "", "gpt-oss-120b"]
    var editor: LineEditor
    var prof = buildProfile(activeCurrent, activeProviders, "")
    var messages = newJArray()
    var session = Session()

    discard handleCommand(":provider edit nvidia", messages, session, prof,
                          editor)

    check activeProviders[0].models == @["openai/gpt-oss-120b"]
    check verifiedModels.len == 0

suite "provider/model order":
  # nvidia's curated order is gpt-oss-120b before gpt-oss-20b; these
  # providers list them reversed, so any re-ranking by KnownGoodCombos
  # would flip the results.
  var
    savedCurrent: string
    savedProviders: seq[ProviderRec]
    savedXdg: string
    hadXdg: bool
    tempConfig: string

  setup:
    savedCurrent = activeCurrent
    savedProviders = activeProviders
    hadXdg = existsEnv("XDG_CONFIG_HOME")
    savedXdg = getEnv("XDG_CONFIG_HOME")
    tempConfig = getTempDir() / ("3code-model-order-" &
      $getCurrentProcessId())
    putEnv("XDG_CONFIG_HOME", tempConfig)
    activeProviders = @[
      ProviderRec(name: "nvidia", url: "https://integrate.api.nvidia.com/v1",
                  key: "nvapi",
                  models: @["openai/gpt-oss-20b", "openai/gpt-oss-120b"])
    ]
    activeCurrent = "nvidia.openai/gpt-oss-20b"

  teardown:
    activeCurrent = savedCurrent
    activeProviders = savedProviders
    if hadXdg:
      putEnv("XDG_CONFIG_HOME", savedXdg)
    else:
      delEnv("XDG_CONFIG_HOME")
    try: removeDir(tempConfig)
    except OSError: discard


  test "switching provider defaults to the first entered model":
    var editor: LineEditor
    var prof = buildProfile(activeCurrent, activeProviders, "")
    var messages = newJArray()
    var session = Session()

    discard handleCommand(":provider nvidia", messages, session, prof, editor)
    check activeCurrent == "nvidia.openai/gpt-oss-20b"
    check prof.model == "openai/gpt-oss-20b"

  test ":model completion cycles in entered order":
    var completions = completionFor(":model ")
    check completions == @["gpt-oss-20b", "gpt-oss-120b"]

  test ":model list shows entered order":
    var editor: LineEditor
    var prof = buildProfile(activeCurrent, activeProviders, "")
    var messages = newJArray()
    var session = Session()

    let listing = handleCommandResult(":model", messages, session,
                                    prof, editor).body
    let i20 = listing.find("gpt-oss-20b")
    let i120 = listing.find("gpt-oss-120b")
    check i20 >= 0 and i120 >= 0 and i20 < i120
