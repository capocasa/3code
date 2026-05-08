# Impl 1: session.nim round-trip tests

**New file:** `tests/test_session.nim`
**Module:** `threecode/session` (also uses `threecode/types`)
**Procs covered:** renderSession, loadSessionFile, usageFromJson, firstUserMessage (public). Indirectly covers ~10 private procs: parseRecords, parseSections, parseArgs, splitPreamble, joinPreamble, recordToToolCall, recordToUsage, emitToolUse, emitTokens, emitRecord, emitHeaderOnly.

## Approach

The core insight: `renderSession` and `loadSessionFile` are inverses. Build a known `Session` + `messages` JSON array → render to text → write to a temp file → `loadSessionFile` → assert the reconstructed messages match the originals. This one round-trip exercises the full parse/emit pipeline.

Private procs are not directly importable — test them through the public API only.

## Imports

```nim
import std/[json, os, strutils, unittest]
import threecode/[session, types]
```

## Test cases

### Suite: "session: usageFromJson"

1. **"parses all fields"**
   ```nim
   let j = %*{"promptTokens": 100, "completionTokens": 50,
               "totalTokens": 150, "cachedTokens": 30}
   let u = usageFromJson(j)
   check u.promptTokens == 100
   check u.completionTokens == 50
   check u.totalTokens == 150
   check u.cachedTokens == 30
   ```

2. **"returns zeros for nil"**
   ```nim
   let u = usageFromJson(nil)
   check u.promptTokens == 0
   check u.totalTokens == 0
   ```

### Suite: "session: firstUserMessage"

3. **"extracts first user message, strips preamble"**
   ```nim
   let msgs = %*[
     {"role": "system", "content": "You are helpful."},
     {"role": "user", "content": "<session_context>\ncwd: /tmp\n</session_context>\n\nHello"},
     {"role": "assistant", "content": "Hi"},
     {"role": "user", "content": "Bye"}
   ]
   check firstUserMessage(msgs) == "Hello"
   ```

4. **"returns empty for empty array"**
   ```nim
   check firstUserMessage(newJArray()) == ""
   ```

### Suite: "session: renderSession → loadSessionFile round-trip"

Use `setup`/`teardown` with a temp file path:

```nim
var tmp: string
setup:
  tmp = getTempDir() / "3code-test-session.3log"
teardown:
  if fileExists(tmp): removeFile(tmp)
```

5. **"round-trips a simple user/assistant conversation"**
   - Build session with `created`, `profileName`, `cwd`.
   - Build messages: system + user + assistant (no tool calls).
   - `renderSession` → write to `tmp` → `loadSessionFile(tmp)`.
   - Assert loaded session fields match: `created`, `profileName`, `cwd`.
   - Assert loaded messages have same roles and content.
   - Note: `loadSessionFile` backfills a system prompt when none is present or the first message isn't system — the rendered file *does* omit system messages, so the loaded version will have a backfilled `DefaultSystemPrompt` at index 0. Account for this by checking that `loaded[0]["role"] == "system"` exists and `loaded[1..^1]` matches the original user/assistant messages.

6. **"round-trips assistant with tool_calls"**
   - Messages: user → assistant with `tool_calls` (bash command `ls -la`, id `call_1`) → tool result (id `call_1`, content `file.txt`).
   - Session with `toolLog` containing one entry for `call_1` with `code: 0`.
   - After round-trip: check `loaded[1]{"tool_calls"}` has length 1, function name `bash`, arguments contain `command: ls -la`.
   - Check `loaded[2]{"role"} == "tool"`, `content == "file.txt"`.

7. **"round-trips write action"**
   - Tool call with name `write`, args `{"path": "src/foo.nim", "body": "echo 1\n"}`.
   - After round-trip: check the write's path and body survive.

8. **"round-trips patch action"**
   - Tool call with name `patch`, args `{"path": "a.nim", "edits": [{"search": "old", "replace": "new"}]}`.
   - After round-trip: check edits survive.

9. **"round-trips usage/tokens"**
   - Assistant message with `"usage": {"promptTokens": 200, "completionTokens": 100, "totalTokens": 300, "cachedTokens": 50, "elapsed": 5}`.
   - After round-trip: check loaded session's `usage.totalTokens` accumulates correctly.

10. **"round-trips reasoning_content"**
    - Assistant with `reasoning_content: "thinking..."` + `content: "answer"`.
    - After round-trip: check loaded assistant has both fields.

11. **"round-trips session_context / project_notes preamble"**
    - User message with `<session_context>...\n</session_context>\n\n<project_notes>...\n</project_notes>\n\nactual message`.
    - After round-trip: check the full preamble + body is reconstructed (compare the user message content string exactly).

12. **"round-trips plan items (update_plan/todo tool)"**
    - Tool call with name `update_plan`, args `{"items": [{"text": "step 1", "status": "completed"}, {"text": "step 2", "status": "pending"}]}`.
    - After round-trip: check tool call args survive.

### Suite: "session: sessionIdFromPath"

13. **"strips .3log extension"**
    ```nim
    check sessionIdFromPath("/some/dir/20250101T120000.3log") == "20250101T120000"
    ```

14. **"returns full name when no extension"**
    ```nim
    check sessionIdFromPath("/some/dir/my-session") == "my-session"
    ```

## Notes

- `loadSessionFile` calls `die()` on file-not-found — don't test that path directly (would quit the process).
- The system prompt is explicitly skipped in `renderSession` and backfilled in `loadSessionFile`, so round-trip tests must account for the backfilled entry.
- `emitToolUse` handles many tool types (bash, shell, write, patch, apply_patch, update_plan/todo) — each should get its own round-trip test.
- The `toolLog` on the `Session` is rebuilt from messages during `loadSessionFile` via `buildToolLogFromMessages`, not preserved from the file — so test the loaded `toolLog` has the right count and kinds.
