# Impl 6: util.nim pure-function tests

**New file:** `tests/test_util.nim`
**Module:** `threecode/util`
**Procs covered:** utf8ByteCut, utf8ByteCutEnd, clipMiddle, humanBytes, humanTokens, tokenSlot, isMdTableRow, renderMdTable, stripPreamble, replaceFirst, isBinaryContent, levenshtein, levenshteinCapped.

## Approach

All pure string/int functions. Feed inputs, assert outputs. Group by functionality area.

Note: `stripPreamble` in util.nim is different from `splitPreamble` in session.nim — the util version just strips the preamble block from a string. Check the source for exact behavior.

## Imports

```nim
import std/[unittest]
import threecode/util
```

## Test cases

### Suite: "util: utf8ByteCut"

1. **"truncates ASCII within limit"**
   ```nim
   check utf8ByteCut("hello", 3) == "hel"
   ```

2. **"returns full string when within limit"**
   ```nim
   check utf8ByteCut("hi", 10) == "hi"
   ```

3. **"does not split a multibyte character"**
   ```nim
   # "é" is 2 bytes in UTF-8 (0xC3 0xA9)
   check utf8ByteCut("étoile", 3) == "é"  # cuts after the 2-byte char, not mid-char
   ```

4. **"handles empty string"**
   ```nim
   check utf8ByteCut("", 5) == ""
   ```

5. **"handles zero limit"**
   ```nim
   check utf8ByteCut("hello", 0) == ""
   ```

### Suite: "util: utf8ByteCutEnd"

6. **"truncates from end within limit"**
   ```nim
   check utf8ByteCutEnd("hello", 3) == "llo"
   ```

7. **"does not split multibyte at end"**
   ```nim
   check utf8ByteCutEnd("café", 4) == "fé"  # keeps the trailing 2-byte char intact
   ```

### Suite: "util: clipMiddle"

8. **"returns full string when within limit"**
   ```nim
   check clipMiddle("hello", 3, 3) == "hello"
   ```

9. **"clips middle with ellipsis"**
   ```nim
   # Check the output format from source — likely uses "…"
   let r = clipMiddle("abcdefghij", 3, 3)
   check r.len < "abcdefghij".len
   check r.startsWith("abc")
   check r.endsWith("hij")
   ```

10. **"handles short string"**
    ```nim
    check clipMiddle("hi", 5, 5) == "hi"
    ```

### Suite: "util: humanBytes"

11. **"formats bytes"**
    ```nim
    check humanBytes(500) == "500B"
    ```

12. **"formats kilobytes"**
    ```nim
    check humanBytes(2048) == "2.0K"
    ```

13. **"formats megabytes"**
    ```nim
    check humanBytes(1048576) == "1.0M"
    ```

14. **"formats zero"**
    ```nim
    check humanBytes(0) == "0B"
    ```

### Suite: "util: humanTokens"

15. **"formats small count"**
    ```nim
    check humanTokens(42) == "42"
    ```

16. **"formats thousands"**
    ```nim
    check humanTokens(1500) == "1.5k"
    ```

17. **"formats zero"**
    ```nim
    check humanTokens(0) == "0"
    ```

### Suite: "util: tokenSlot"

18. **"returns icon + formatted count"**
    ```nim
    let r = tokenSlot("●", 500)
    check "●" in r
    check "500" in r
    ```

### Suite: "util: isMdTableRow"

19. **"detects markdown table row"**
    ```nim
    check isMdTableRow("| a | b | c |")
    ```

20. **"rejects non-table line"**
    ```nim
    check not isMdTableRow("just some text")
    ```

### Suite: "util: renderMdTable"

21. **"renders a simple table"**
    ```nim
    let rows = @["| a | b |", "| 1 | 2 |"]
    let rendered = renderMdTable(rows)
    check "| a | b |" in rendered
    check "| 1 | 2 |" in rendered
    ```
    Note: Check the source for exact output format (separator row insertion, alignment).

22. **"handles empty input"**
    ```nim
    check renderMdTable(@[]) == ""
    ```

### Suite: "util: stripPreamble"

23. **"strips session_context block"**
    ```nim
    let s = "<session_context>\ncwd: /tmp\n</session_context>\n\nHello"
    check stripPreamble(s) == "Hello"
    ```

24. **"returns original when no preamble"**
    ```nim
    check stripPreamble("just text") == "just text"
    ```

### Suite: "util: replaceFirst"

25. **"replaces first occurrence"**
    ```nim
    let (result, found) = replaceFirst("hello world hello", "hello", "hi")
    check result == "hi world hello"
    check found == true
    ```

26. **"returns original when needle not found"**
    ```nim
    let (result, found) = replaceFirst("hello", "xyz", "abc")
    check result == "hello"
    check found == false
    ```

### Suite: "util: isBinaryContent"

27. **"detects binary content"**
    ```nim
    check isBinaryContent("\x00\x01\x02binary data")
    ```

28. **"allows normal text"**
    ```nim
    check not isBinaryContent("Hello, world!")
    ```

29. **"allows UTF-8 text with non-ASCII"**
    ```nim
    check not isBinaryContent("café résumé")
    ```

### Suite: "util: levenshtein"

30. **"computes edit distance"**
    ```nim
    check levenshtein("kitten", "sitting") == 3
    ```

31. **"zero for identical strings"**
    ```nim
    check levenshtein("same", "same") == 0
    ```

32. **"length difference for empty string"**
    ```nim
    check levenshtein("", "abc") == 3
    check levenshtein("abc", "") == 3
    ```

### Suite: "util: levenshteinCapped"

33. **"returns actual distance when under cap"**
    ```nim
    check levenshteinCapped("abc", "axc", 5) == 1
    ```

34. **"returns cap when distance exceeds it"**
    ```nim
    let d = levenshteinCapped("abcdef", "xyzuvw", 3)
    check d == 3  # capped, actual distance is 6
    ```

35. **"returns 0 for identical"**
    ```nim
    check levenshteinCapped("same", "same", 10) == 0
    ```

## Notes

- Read each proc's source before writing the test — `humanBytes` and `humanTokens` may use different formatting (e.g., "KB" vs "K", "1,000" vs "1.0k").
- `stripPreamble` in util.nim may differ from session.nim's `splitPreamble` — verify it simply removes the preamble block rather than splitting into components.
- `renderMdTable` has several parameters (`indent`, `maxWidth`) — test the defaults first, then optionally with custom values.
- `isBinaryContent` likely checks for null bytes or other binary markers — read the source to understand the heuristic.
