# Test Coverage Implementation Plan

Derived from `test-audit.md`. Seven implementation instruction files, one per
batch of related changes. Execute in order — later batches may build on types
or helpers introduced earlier, but each file is self-contained.

## Batches

| # | File | Module(s) | New test file | Untested procs covered |
|---|------|-----------|---------------|----------------------|
| 1 | `impl-1-session.md` | session.nim | `tests/test_session.nim` | ~15: parseRecords, parseSections, splitPreamble/joinPreamble, recordToToolCall, recordToUsage, emitToolUse, emitTokens, renderSession→loadSessionFile round-trip |
| 2 | `impl-2-actions.md` | actions.nim | `tests/test_actions_text.nim` | parseActions, parseActionsChecked, stripActions, parseV4APatch, computeDiff |
| 3 | `impl-3-shell.md` | shell.nim | `tests/test_shell.nim` | shellTokens, splitStatements, bashMutationPath, bashReadPath, bashIsRecovery |
| 4 | `impl-4-config.md` | config.nim | `tests/test_config_pipeline.nim` | shortModel, shortToFull, findModel, resolveFamily, resolveReasoning, buildProfile, inferProvider, curatedFor, orderedModels, gateExperimental |
| 5 | `impl-5-api.md` | api.nim | `tests/test_api_pure.nim` | parseUsage, classifyRetry, applyReasoning (deepseek, gpt-oss, minimax families) |
| 6 | `impl-6-util.md` | util.nim | `tests/test_util.nim` | utf8ByteCut, clipMiddle, humanBytes, humanTokens, tokenSlot, isMdTableRow, renderMdTable, stripPreamble, replaceFirst, isBinaryContent, levenshtein, levenshteinCapped |
| 7 | `impl-7-prompts-compact.md` | prompts.nim, compact.nim | `tests/test_prompts_compact.nim` | knownGoodFamily, isKnownGood, knownGoodTags, knownGoodReasoning, reasoningSupported, defaultReasoningsFor, buildCredit, contextWindowFor, decideContextAction |

## Conventions

- All tests are **offline** — no network, no filesystem beyond `/tmp` scratch files.
- Use `import std/[json, strutils, unittest]` and `import threecode/[module]`.
- Test file goes in `tests/`, compiled with `nim c -r tests/test_X.nim` (the `config.nims` adds `src` to the path).
- Follow existing test style: `suite`/`test` blocks, flat assertions, minimal setup.
- Each instruction file lists: imports, test file path, test cases with input/output expectations, and notes on edge cases.

## Running all tests

```sh
for f in tests/test_*.nim; do nim c -r "$f" || break; done
```
