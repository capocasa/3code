import std/[json, strutils, unicode, unittest]
import threecode/util

suite "util: utf8ByteCut":
  test "truncates ASCII within limit":
    check utf8ByteCut("hello", 3) == "hel"

  test "returns full string when within limit":
    check utf8ByteCut("hi", 10) == "hi"

  test "does not split a multibyte character":
    check utf8ByteCut("étoile", 3) == "ét"  # "é" is 2 bytes, byte 3 is 't'

  test "handles empty string":
    check utf8ByteCut("", 5) == ""

  test "handles zero limit":
    check utf8ByteCut("hello", 0) == ""

suite "util: utf8ByteCutEnd":
  test "truncates from end within limit":
    check utf8ByteCutEnd("hello", 3) == "llo"

  test "does not split multibyte at end":
    check utf8ByteCutEnd("café", 4) == "afé"

  test "returns full string when within limit":
    check utf8ByteCutEnd("hello", 10) == "hello"

  test "handles empty string":
    check utf8ByteCutEnd("", 5) == ""

suite "util: sanitizeUtf8":
  test "passes ASCII through unchanged":
    check sanitizeUtf8("plain ascii") == "plain ascii"

  test "preserves valid multibyte codepoints":
    check sanitizeUtf8("\u276F caf\u00E9") == "\u276F caf\u00E9"

  test "empty string stays empty":
    check sanitizeUtf8("") == ""

  test "replaces a lone continuation byte with U+FFFD":
    # The exact poison: a lone 0xAF (the final byte of ❯ = E2 9D AF) sitting
    # mid-ASCII after its lead bytes were dropped from captured tool output.
    var s = "editorText: "
    s.add chr(0xAF)
    s.add " this"
    let r = sanitizeUtf8(s)
    check r == "editorText: \uFFFD this"

  test "replaces a truncated multi-byte lead with U+FFFD":
    # E2 9D without the AF tail — the truncated rune that produced this bug.
    var s = "x"
    s.add chr(0xE2)
    s.add chr(0x9D)
    let r = sanitizeUtf8(s)
    check r == "x\uFFFD\uFFFD"

  test "result is valid UTF-8":
    var s = "a"
    s.add chr(0xAF)
    s.add "b"
    let r = sanitizeUtf8(s)
    # U+FFFD round-trips through rune iteration without error.
    check r.toRunes.len == 3

  test "a serialized body with invalid UTF-8 parses as JSON after sanitize":
    # Mirrors how both call sites use it: the body is serialized first, then
    # sanitized, and the result must still be valid JSON the provider accepts.
    var poison = "editorText: "
    poison.add chr(0xAF)
    poison.add " done"
    let body = %*{"model": "m",
                   "messages": [%*{"role": "tool", "content": poison}]}
    let wire = sanitizeUtf8($body)
    let back = parseJson(wire)
    check back{"messages"}[0]{"content"}.getStr == "editorText: \uFFFD done"

suite "util: clipMiddle":
  test "returns full string when within limit":
    check clipMiddle("hello", 3, 3) == "hello"

  test "clips middle with ellipsis":
    let r = clipMiddle("abcdefghij", 3, 3)
    check r.len > 0  # result is longer due to truncation marker
    check r.startsWith("abc")
    check r.endsWith("hij")
    check r.contains("... [truncated] ...")

  test "handles short string":
    check clipMiddle("hi", 5, 5) == "hi"

suite "util: humanBytes":
  test "formats bytes":
    check humanBytes(500) == "500B"

  test "formats kilobytes":
    check humanBytes(2048) == "2.0KB"

  test "formats megabytes":
    check humanBytes(1048576) == "1.00MB"

  test "formats zero":
    check humanBytes(0) == "0B"

suite "util: humanTokens":
  test "formats small count":
    check humanTokens(42) == "42"

  test "formats thousands":
    check humanTokens(1500) == "1.5k"

  test "formats zero":
    check humanTokens(0) == "0"

suite "util: tokenSlot":
  test "returns icon + formatted count":
    let r = tokenSlot("●", 500)
    check r.startsWith("●")
    check "500" in r

  test "returns empty for zero":
    check tokenSlot("●", 0) == ""

suite "util: isMdTableRow":
  test "detects markdown table row":
    check isMdTableRow("| a | b | c |")

  test "rejects non-table line":
    check not isMdTableRow("just some text")

  test "rejects line with only opening pipe":
    check not isMdTableRow("| a | b | c")

  test "strips whitespace":
    check isMdTableRow("  | a | b |  ")

suite "util: renderMdTable":
  test "renders a simple table":
    let rows = @["| a | b |", "| --- | --- |", "| 1 | 2 |"]
    let rendered = renderMdTable(rows)
    check rendered.len > 0
    check "│" in rendered
    check "┌" in rendered

  test "handles empty input":
    check renderMdTable(@[]) == ""

suite "util: stripPreamble":
  test "strips session_context block":
    let s = "<session_context>\ncwd: /tmp\n</session_context>\n\nHello"
    check stripPreamble(s) == "Hello"

  test "returns original when no preamble":
    check stripPreamble("just text") == "just text"

  test "strips project_notes too":
    let s = "<session_context>\ncwd: /tmp\n</session_context>\n<project_notes>\nnote\n</project_notes>\nBody"
    check stripPreamble(s) == "Body"

suite "util: replaceFirst":
  test "replaces first occurrence":
    let (result, found) = replaceFirst("hello world hello", "hello", "hi")
    check result == "hi world hello"
    check found == true

  test "returns original when needle not found":
    let (result, found) = replaceFirst("hello", "xyz", "abc")
    check result == "hello"
    check found == false

suite "util: isBinaryContent":
  test "detects binary content":
    check isBinaryContent("\x00\x01\x02binary data")

  test "allows normal text":
    check not isBinaryContent("Hello, world!")

  test "allows UTF-8 text with non-ASCII":
    check not isBinaryContent("café résumé")

  test "returns false for empty string":
    check not isBinaryContent("")

suite "util: levenshtein":
  test "computes edit distance":
    check levenshtein("kitten", "sitting") == 3

  test "zero for identical strings":
    check levenshtein("same", "same") == 0

  test "length difference for empty string":
    check levenshtein("", "abc") == 3
    check levenshtein("abc", "") == 3

suite "util: levenshteinCapped":
  test "returns actual distance when under cap":
    check levenshteinCapped("abc", "axc", 5) == 1

  test "returns cap+1 when distance exceeds it":
    check levenshteinCapped("abcdef", "xyzuvw", 3) == 4

  test "returns 0 for identical":
    check levenshteinCapped("same", "same", 10) == 0

  test "early exit on length gap":
    check levenshteinCapped("a", "abcdefg", 3) == 4

suite "util: charWrapAnsi":
  test "short string fits in one line":
    check charWrapAnsi("hello", 10) == @["hello"]

  test "wraps at exact character boundary":
    check charWrapAnsi("abcdefghij", 5) == @["abcde", "fghij"]

  test "wraps mid-word":
    check charWrapAnsi("abcdefghijklmnop", 4) == @["abcd", "efgh", "ijkl", "mnop"]

  test "handles empty string":
    check charWrapAnsi("", 10) == @[""]

  test "handles zero width":
    check charWrapAnsi("hello", 0) == @["hello"]

  test "single character width":
    check charWrapAnsi("abc", 1) == @["a", "b", "c"]

suite "util: visibleWidth unicode":
  test "ASCII counts as 1":
    check visibleWidth("hello") == 5

  test "CJK rune counts as 2":
    check visibleWidth("中") == 2
    check visibleWidth("a中b") == 4

  test "emoji counts as 2":
    check visibleWidth(Rune(0x1F600).toUTF8) == 2

  test "combining mark is zero-width":
    # 'e' followed by U+0301 combining acute
    check visibleWidth("e\u0301") == 1

  test "ANSI escape does not count":
    check visibleWidth("\x1b[31mhi\x1b[0m") == 2

  test "mixed ANSI, CJK, combining":
    # red '中' + combining acute: 2 cells
    check visibleWidth("\x1b[31m中\u0301\x1b[0m") == 2

  test "malformed UTF-8 does not crash":
    # Binary file bytes (0xFF 0xFE 0xFD ...) decoded by runeAt yield
    # code points beyond U+10FFFF, which unicodedb would otherwise
    # assert on. Each such byte counts as one cell.
    check visibleWidth("\xff\xfe\xfd") == 3

suite "util: repairToolCallPairing":
  test "drops leading orphan tool results":
    let messages = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": "Earlier in this session: recap"},
      {"role": "tool", "tool_call_id": "call_B", "content": "b"},
      {"role": "user", "content": "go on"}
    ]
    let repaired = repairToolCallPairing(messages)
    check repaired.len == 3
    check repaired[0]{"role"}.getStr == "system"
    check repaired[1]{"role"}.getStr == "user"
    check repaired[2]{"role"}.getStr == "user"

  test "injects synthetic results for unpaired tool_calls":
    let messages = %*[
      {"role": "assistant", "content": "",
       "tool_calls": [{"id": "call_1", "type": "function",
                        "function": {"name": "bash", "arguments": "{}"}}]},
      {"role": "user", "content": "next"}
    ]
    let repaired = repairToolCallPairing(messages)
    check repaired.len == 3
    check repaired[1]{"role"}.getStr == "tool"
    check repaired[1]{"tool_call_id"}.getStr == "call_1"
    check UnavailableToolResult in repaired[1]{"content"}.getStr

  test "fills empty tool_call ids and pairs empty tool_call_id":
    let messages = %*[
      {"role": "assistant", "content": "",
       "tool_calls": [{"id": "", "type": "function",
                        "function": {"name": "bash", "arguments": "{}"}}]},
      {"role": "tool", "tool_call_id": "", "content": "ok"}
    ]
    let repaired = repairToolCallPairing(messages)
    check repaired.len == 2
    check repaired[0]{"tool_calls"}[0]{"id"}.getStr == "fill-1"
    check repaired[1]{"tool_call_id"}.getStr == "fill-1"

  test "keeps a well-formed parallel batch":
    let messages = %*[
      {"role": "assistant", "content": "",
       "tool_calls": [
         {"id": "A", "type": "function", "function": {"name": "bash", "arguments": "{}"}},
         {"id": "B", "type": "function", "function": {"name": "bash", "arguments": "{}"}}
       ]},
      {"role": "tool", "tool_call_id": "A", "content": "a"},
      {"role": "tool", "tool_call_id": "B", "content": "b"}
    ]
    let repaired = repairToolCallPairing(messages)
    check repaired.len == 3
    check repaired[1]{"tool_call_id"}.getStr == "A"
    check repaired[2]{"tool_call_id"}.getStr == "B"
