
  Full Test Coverage Audit
                                                                    Test inventory                                                  
  ┌───────────────────────┬──────┬───────────────────────────────┐
  │ Test file             │ LOC  │ Primary targets               │
  ├───────────────────────┼──────┼───────────────────────────────┤
  │ test_api.nim          │ ~140 │ api.nim — streaming opts,     │
  │                       │      │ generation defaults,          │
  │                       │      │ reasoning (GLM only), XML     │
  │                       │      │ tool parsing, verifyBody      │
  ├───────────────────────┼──────┼───────────────────────────────┤
  │ test_config.nim       │ ~30  │ config.nim — parseConfigFile  │
  │                       │      │ search-url only               │
  ├───────────────────────┼──────┼───────────────────────────────┤
  │ test_footer.nim       │ ~830 │ api.nim/display.nim — token   │
  │                       │      │ bar ANSI byte sequences, full │
  │                       │      │ turn lifecycle                │
  ├───────────────────────┼──────┼───────────────────────────────┤
  │ test_golden.nim       │ ~170 │ display.nim — exact render    │
  │                       │      │ output for tool banners,      │
  │                       │      │ token lines, assistant        │
  │                       │      │ content                       │
  ├───────────────────────┼──────┼───────────────────────────────┤
  │ test_history.nim      │ ~250 │ minline.nim — history nav,    │
  │                       │      │ persistence, cursor           │
  │                       │      │ preservation, dedup           │
  ├───────────────────────┼──────┼───────────────────────────────┤
  │ test_minline.nim      │ ~500 │ minline.nim — visual layout,  │
  │                       │      │ multiline editing, bracketed  │
  │                       │      │ paste                         │
  ├───────────────────────┼──────┼───────────────────────────────┤
  │ test_parser.nim       │ ~120 │ actions.nim —                 │
  │                       │      │ toolCallToAction dispatch,    │
  │                       │      │ malformed-args fuzzing        │
  ├───────────────────────┼──────┼───────────────────────────────┤
  │ test_replay.nim       │ ~460 │ loop.nim/compact.nim/actions.nim │
  │                       │      │ — failure session replay,     │
  │                       │      │ loop tracker, trip points     │
  ├───────────────────────┼──────┼───────────────────────────────┤
  │ test_render.nim       │ ~150 │ display.nim/util.nim —        │
  │                       │      │ live-vs-replay parity, inline │
  │                       │      │ markdown                      │
  ├───────────────────────┼──────┼───────────────────────────────┤
  │ test_update.nim       │ ~100 │ update.nim — semver compare,  │
  │                       │      │ config gate                   │
  ├───────────────────────┼──────┼───────────────────────────────┤
  │ test_web.nim          │ ~50  │ web.nim — HTML stripping,     │
  │                       │      │ entity decode, search parsing │
  ├───────────────────────┼──────┼───────────────────────────────┤
  │ test_windows_keys.nim │ ~120 │ minline.nim — Windows console │
  │                       │      │ key dispatch                  │
  └───────────────────────┴──────┴───────────────────────────────┘

  Module-level coverage summary

  Module: api.nim
  LOC: 1475
  Exported procs: ~20
  Tested procs: ~7
  Assessment: parseUsage, classifyRetry, fetchModels, verifyProfile, applyReasoning (3 of 4 families untested) have no unit tests. Streaming/HTTP layer is integration-only.

  Module: session.nim
  LOC: 691
  Exported procs: 13
  Tested procs: 0
  Assessment: Largest gap. Zero dedicated tests. renderSession↔loadSessionFile round-trip is untested. parseRecords, parseSections, splitPreamble/joinPreamble, recordToToolCall, recordToUsage are all pure functions with no coverage.

  Module: config.nim
  LOC: 443
  Exported procs: 22
  Tested procs: 1
  Assessment: Only parseConfigFile's search-url path is tested. shortModel, shortToFull, buildProfile, loadProfile, resolveFamily, resolveReasoning, inferProvider, curatedFor, orderedModels, gateExperimental — all untested pure logic.

  Module: prompts.nim
  LOC: 1143
  Exported procs: 17
  Tested procs: 2
  Assessment: Only xmlToolCallsFallback and setup (implicitly via verifyBody) tested. knownGoodFamily, isKnownGood, knownGoodTags, knownGoodReasoning, reasoningSupported, defaultReasoningsFor, buildCredit — all untested.

  Module: shell.nim
  LOC: ~200
  Exported procs: 4
  Tested procs: 0
  Assessment: shellTokens, splitStatements, bashMutationPath, bashRecoveryCommand — all pure functions, all untested. These are non-trivial parsers.

  Module: actions.nim
  LOC: 773
  Exported procs: 13
  Tested procs: 6
  Assessment: toolCallToAction + fuzzing is well-covered. parseActions/parseActionsChecked/stripActions (text-mode fence parser), computeDiff, parseV4APatch — all untested.

  Module: compact.nim
  LOC: ~260
  Exported procs: 6
  Tested procs: 2
  Assessment: compactHistory/supersedeCompact exercised in replay harness. contextWindowFor, decideContextAction, applySummary, summarizeHistory — untested pure logic.

  Module: loop.nim
  LOC: ~120
  Exported procs: 6
  Tested procs: 5
  Assessment: trackCall/fingerprint/isMutationCall well-covered in test_replay. Only resetLoopTracker is trivially tested. Good coverage.

  Module: ui.nim
  LOC: 808
  Exported procs: 11
  Tested procs: 0
  Assessment: Interactive UI — handleCommand, buildUserMessage, inlineAtFiles, completionFor, promptNewProvider/promptEditProvider —
 none tested. Some are inherently hard to unit-test, but handleCommand's colon-command dispatch and inlineAtFiles are pure logic.

  Module: util.nim
  LOC: 506
  Exported procs: 26
  Tested procs: ~10
  Assessment: applyInlineMd, wrapAnsi, visibleWidth tested via test_render/test_golden. utf8ByteCut, clipMiddle, humanBytes, humanTokens, tokenSlot, isMdTableRow, renderMdTable, stripPreamble, replaceFirst, isBinaryContent, levenshtein, levenshteinCapped — all untested pure functions.

  Module: display.nim
  LOC: 664
  Exported procs: 10
  Tested procs: 5
  Assessment: Render helpers well-covered via golden + footer tests. printActionResult, showProfile, printKnownGood, printSessionList, showTool, listTools — untested I/O helpers (lower priority).

  Module: update.nim
  LOC: ~200
  Exported procs: 5
  Tested procs: 3
  Assessment: semverGt, parseSemver, autoUpdateEnabled well-tested. cleanupStaleBinaries, spawnBackgroundUpdateMaybe are side-effectful / process-level — reasonably untested.

  Module: web.nim
  LOC: ~100
  Exported procs: 5
  Tested procs: 5
  Assessment: Good coverage — decodeEntities, stripHtml, parseSearchHits, capText.

  Module: minline.nim
  LOC: 1092
  Exported procs: ~15
  Tested procs: ~10
  Assessment: Layout, history, bracketed paste, Windows keys all tested. Gaps: completion cycling (Tab/Shift+Tab), ESC-cancel, password, multiline arrow navigation, resize handling.

  Module: types.nim
  LOC: ~50
  Exported procs: 1
  Tested procs: 0
  Assessment: Trivial type definitions — no tests needed.


  High-priority gaps (pure logic, easy to test, high impact)

  1. session.nim — full round-trip. renderSession →
  loadSessionFile is the persistence format for every session. A
  single round-trip test (build a known messages JSON →
  renderSession → loadSessionFile → assert the JSON comes back)
  would cover parseRecords, parseSections,
  splitPreamble/joinPreamble, recordToToolCall, recordToUsage,
  emitToolUse, emitTokens — 15+ procs at once. This is the single
  biggest coverage win available.

  2. actions.nim — parseActions / parseActionsChecked. The
  text-mode fence parser handles ``bash, path+`write, and           SEARCH/REPLACE patches. It's what runs when models emit           non-tool-call actions. Currently zero tests despite non-trivial
  parsing logic and explicit error detection (ParseIssue`).

  3. shell.nim — all 4 procs. shellTokens, splitStatements,
  bashMutationPath, bashRecoveryCommand are all pure
  string-processing functions used by the loop guard. They handle
  quoting, pipe splitting, and pattern matching against shell
  commands — classic parser bugs live here.

  4. config.nim — model resolution pipeline. shortModel,
  shortToFull, buildProfile, resolveFamily, resolveReasoning,
  inferProvider, curatedFor are all pure functions that drive
  provider/model selection. Currently only the config-file parser
  gets 4 tests.

  5. api.nim — parseUsage and classifyRetry. Pure logic,
  high-impact (wrong usage parsing means broken token bar; wrong
  retry classification means spurious retries or missed ones).
  Zero tests.

  6. api.nim — applyReasoning for 3 families. Only GLM reasoning
  is tested. DeepSeek, GPT-OSS, and MiniMax reasoning wire formats
  are untested. Each is a ~5-line proc, trivial to test.

  7. compact.nim — contextWindowFor and decideContextAction.
  contextWindowFor does substring matching on model names
  (collision-prone heuristic). decideContextAction is a pure
  Assessment: compactHistory/supersedeCompact exercised [110/1855]
harness. contextWindowFor, decideContextAction, applySummary, summ
arizeHistory — untested pure logic.

  Module: loop.nim
  LOC: ~120
  Exported procs: 6
  Tested procs: 5
  Assessment: trackCall/fingerprint/isMutationCall well-covered in
 test_replay. Only resetLoopTracker is trivially tested. Good cove
rage.

  Module: ui.nim
  LOC: 808
  Exported procs: 11
  Tested procs: 0
  Assessment: Interactive UI — handleCommand, buildUserMessage, in
lineAtFiles, completionFor, promptNewProvider/promptEditProvider —
 none tested. Some are inherently hard to unit-test, but handleCom
mand's colon-command dispatch and inlineAtFiles are pure logic.

  Module: util.nim
  LOC: 506
  Exported procs: 26
  Tested procs: ~10
  Assessment: applyInlineMd, wrapAnsi, visibleWidth tested via tes
t_render/test_golden. utf8ByteCut, clipMiddle, humanBytes, humanTo
kens, tokenSlot, isMdTableRow, renderMdTable, stripPreamble, repla
ceFirst, isBinaryContent, levenshtein, levenshteinCapped — all unt
ested pure functions.
