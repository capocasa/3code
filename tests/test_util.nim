import std/[strutils, unittest]
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
