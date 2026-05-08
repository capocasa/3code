# Impl 2: actions.nim text-mode parser tests

**New file:** `tests/test_actions_text.nim`
**Module:** `threecode/actions`
**Procs covered:** parseActions, parseActionsChecked, stripActions, computeDiff, parseV4APatch (private but called through runAction on apply_patch kind; test computeDiff and the fence-parsers directly).

## Approach

`parseActions` and `parseActionsChecked` handle "text-mode" tool call parsing — when a model emits ` ```bash `, ` ```write path+`, and SEARCH/REPLACE blocks inside fenced code instead of using the tool_call API. These are critical parsers with zero test coverage.

`parseV4APatch` is private but `parseActions` delegates to it for `*** Begin Patch` blocks. Test via parseActions when possible.

`computeDiff` is public and pure — easy to test directly.

## Imports

```nim
import std/[json, strutils, unittest]
import threecode/[actions, types]
```

## Test cases

### Suite: "actions: computeDiff"

1. **"detects a single changed line"**
   ```nim
   let diff = computeDiff("line1\nline2\nline3\n", "line1\nLINE2\nline3\n", "test.txt")
   check "LINE2" in diff
   check "test.txt" in diff
   ```

2. **"returns empty string for identical content"**
   ```nim
   check computeDiff("abc\n", "abc\n", "f.txt") == ""
   ```

3. **"shows added and removed markers"**
   ```nim
   let diff = computeDiff("a\n", "b\n", "f.txt")
   check diff.contains("-") or diff.contains("+") or diff.contains("b")
   ```

### Suite: "actions: parseActions — bash fences"

Read the source to understand the exact fence syntax accepted. The parser looks for:
- ` ```bash ` followed by content and closing ` ``` `
- ` ```write path ` (or `path+` for overwrite)
- ` ```patch path ` with SEARCH/REPLACE blocks inside
- ` ```apply_patch ` for V4A format

4. **"parses a single bash fence"**
   Construct an assistant message text with a bash code fence containing `ls -la`. Call `parseActions`. Check it returns one `Action` of kind `akBash` with `body == "ls -la"`.

5. **"parses multiple fences"**
   Text with two bash fences. Check `result.len == 2`.

6. **"returns empty for plain prose"**
   ```nim
   check parseActions("Just some text without any fences.").len == 0
   ```

### Suite: "actions: parseActions — write fences"

7. **"parses write fence with path"**
   Text with ` ```write src/foo.nim\ncontent\n``` `. Check `akWrite`, `path == "src/foo.nim"`, `body == "content"`.

8. **"parses write with path+ (overwrite marker)"**
   Same but path ends with `+`. Check path has `+` stripped.

### Suite: "actions: parseActions — patch fences"

9. **"parses SEARCH/REPLACE inside patch fence"**
   Text with ` ```patch src/foo.nim\n>>>>>>> SEARCH\nold\n=======\nnew\n>>>>>>> REPLACE\n``` `. Check `akPatch`, `path == "src/foo.nim"`, `edits.len == 1`, `edits[0] == ("old", "new")`.

10. **"parses multiple SEARCH/REPLACE blocks in one fence"**
    Two SEARCH/REPLACE pairs. Check `edits.len == 2`.

### Suite: "actions: parseActionsChecked"

11. **"returns empty issues for valid bash fence"**
    The same valid bash text from test 4. Check the `issues` seq is empty.

12. **"detects unterminated fence"**
    Text with ` ```bash\ncommand` but no closing ` ``` `. Check `issues.len > 0` and an issue mentions the unclosed fence.

13. **"detects orphan backticks"**
    Text with stray ` ``` ` not preceded by a tool name. Check it surfaces a `ParseIssue`.

### Suite: "actions: stripActions"

14. **"strips bash fences, leaves prose"**
    Input: `"Here is what I'll do:\n```bash\necho hi\n```\nDone."`
    Output should contain "Here is what I'll do:" and "Done." but not `echo hi`.

15. **"returns original text when no fences"**
    ```nim
    check stripActions("plain text") == "plain text"
    ```

### Suite: "actions: parseActions — apply_patch (V4A format)"

16. **"parses a V4A Begin/End Patch with an Add File"**
    Text containing:
    ```
    *** Begin Patch
    *** Add File: new.txt
    +hello world
    *** End Patch
    ```
    Check it returns one `akApplyPatch` action.

## Notes

- Read `parseActions` source carefully (lines ~605–750) before writing tests — the fence-matching regex/logic determines exactly what whitespace/formatting is expected.
- The fence language tags may be case-sensitive or have specific naming conventions. Check the source.
- `parseActionsChecked` returns a tuple `(actions: seq[Action], issues: seq[ParseIssue])` — the exact return type should be confirmed from the source. It's likely `tuple[actions: seq[Action], issues: seq[ParseIssue]]` or similar.
- `computeDiff` uses unified-diff format — check the source for the exact output format before asserting on specific strings.
