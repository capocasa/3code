import std/[strutils, unicode, unittest]
import threecode/[fatprompt, types]

proc checkFrame(p: FatPrompt; rows: openArray[string]) =
  let expected = @rows.join("\n")
  check p.frameText() == expected

suite "ticker clamping":
  test "clampToWidth truncates to terminal width":
    check clampToWidth("hello world", 5) == "hello"
    check clampToWidth("hello world", 20) == "hello world"
    check clampToWidth("", 5) == ""
    check clampToWidth("abcdefghij", 0) == ""

  test "narrow terminal clamps ticker in footer bytes":
    let long = "the quick brown fox jumps over the lazy dog"
    let f = FooterFrame(kind: ffSpinner, spinner: "⠋", label: "thinking",
                        ticker: long, elapsed: 3)
    let wide = f.footerFrameBytes(termW = 120)
    let narrow = f.footerFrameBytes(termW = 15)
    # wide terminal still shows the full ticker
    check long in wide
    # narrow terminal does not emit the full (wrapping) ticker
    check long notin narrow

  test "rowsAboveEditor counts ticker as one row":
    let f = FooterFrame(kind: ffSpinner, spinner: "⠋", label: "thinking",
                        ticker: "x".repeat(200), elapsed: 3)
    check f.rowsAboveEditor(termW = 40) == f.rowsAboveEditor(termW = 80)

  test "no-bar footer still reserves the ticker gap row":
    # The design's "ticker as distance" rule: the gap row above the editor
    # is reserved chrome even when no token bar exists, so a bar or spinner
    # appearing later never shifts committed scrollback.
    let f = noFooterFrame()
    check f.rowsAboveEditor(termW = 80) == 1
    # The byte paint must occupy exactly one (blank) row and move no rows:
    # the editor redraw's trailing newline is what advances past it.
    check f.footerFrameBytes(termW = 80) == "\r\x1b[2K"

  test "prompt-only state frame paints one blank gap row":
    var s = initFatPromptState()
    check s.footerFrameBytes(termW = 80) == "\r\x1b[2K"
    # With a bar the frame is gap row + bar row(s).
    s.apply setBarEvent("○0%  ↑10", hasGap = true)
    check "\r\n" in s.footerFrameBytes(termW = 80)

suite "fat prompt frame model":
  test "token bar and editor reserve rows below scrollback":
    var p = initFatPrompt(width = 30, height = 6, window = 1000)
    p.addScrollLine "one"
    p.addScrollLine "two"
    p.addScrollLine "three"
    p.setTokenBar(Usage(promptTokens: 20, totalTokens: 20), window = 1000)
    p.setEditor "hello"

    # The ticker row is always reserved now (an empty gap between
    # scrollback and the bar reads better than flush adjacency), so the
    # bottom scrollback line drops out of view and the gap is two rows.
    p.checkFrame ["two", "three", "", "", "○2%  ↑20", "❯ hello"]

  test "ticker reserves its own row above token bar":
    var p = initFatPrompt(width = 30, height = 6, window = 1000)
    for line in ["one", "two", "three", "four"]:
      p.addScrollLine line
    p.setTicker "thinking..."
    p.setTokenBar(Usage(promptTokens: 20, totalTokens: 20), window = 1000,
                  apiActive = true, spinner = "◐", elapsedS = 7)
    p.setEditor "hello"

    p.checkFrame ["three", "four", "", "thinking...",
                  "◐  ○2%  ↑20  7s", "❯ hello"]

    p.setTicker ""
    p.checkFrame ["three", "four", "", "", "◐  ○2%  ↑20  7s",
                  "❯ hello"]

  test "multiline editor grows reserved area and shrinking reveals scrollback":
    var p = initFatPrompt(width = 18, height = 7, window = 1000)
    for line in ["one", "two", "three", "four", "five"]:
      p.addScrollLine line
    p.setTokenBar(Usage(promptTokens: 20, totalTokens: 20), window = 1000)
    p.setEditor "alpha\nbeta"

    p.checkFrame ["four", "five", "", "", "○2%  ↑20", "❯ alpha",
                  "  beta"]

    p.setEditor "short"
    p.checkFrame ["three", "four", "five", "", "", "○2%  ↑20",
                  "❯ short"]

  test "wrapped editor height reserves every visual row":
    var p = initFatPrompt(width = 10, height = 7, window = 1000)
    for line in ["one", "two", "three", "four", "five"]:
      p.addScrollLine line
    p.setTokenBar(Usage(promptTokens: 20, totalTokens: 20), window = 1000)
    p.setEditor "abcdefghijk"

    p.checkFrame ["four", "five", "", "", "○2%  ↑20", "❯ abcdefgh",
                  "  ijk"]

  test "wrapping keeps unicode runes intact":
    var p = initFatPrompt(width = 8, height = 5, window = 1000)
    p.addScrollLine "one"
    p.setTokenBar(Usage(promptTokens: 20, totalTokens: 20), window = 1000)
    p.setEditor "abédefg"

    p.checkFrame ["", "", "○2%  ↑20", "❯ abédef", "  g"]

  test "token bar always keeps context and only shows nonzero token slots":
    var p = initFatPrompt(width = 40, height = 3, window = 128000)
    p.setTokenBar(Usage(), window = 128000)
    p.setEditor ""
    check tokenBarText(p.tokenBar) == "○0%"

    p.setTokenBar(Usage(promptTokens: 2000, cachedTokens: 500,
                        completionTokens: 25, totalTokens: 2025),
                  window = 128000, apiActive = true, spinner = "●",
                  elapsedS = 3)
    check tokenBarText(p.tokenBar) == "●  ○1%  ↑2.0k  ↻500  ↓25  3s"

    p.setTokenBar(Usage(promptTokens: 16, cachedTokens: 3200,
                        completionTokens: 36, totalTokens: 52),
                  window = 128000, apiActive = true, spinner = "○",
                  elapsedS = 3)
    check tokenBarText(p.tokenBar) == "○  ○0%  ↑16  ↻3.2k  ↓36  3s"

  test "bash viewport shows cutoff plus bottom seven while active":
    var p = initFatPrompt(width = 50, height = 13, window = 1000)
    p.addTranscriptItem(pmUser, "run command")
    p.setTokenBar(Usage(promptTokens: 10, totalTokens: 10), window = 1000)
    p.setEditor "next"
    p.beginBash(idx = 4)
    for i in 1 .. 9:
      p.pushBashOutput "bash-line-" & $i

    p.checkFrame ["", "$ ... 2 lines omitted :show 4 for full",
                  "$ bash-line-3", "$ bash-line-4", "$ bash-line-5",
                  "$ bash-line-6", "$ bash-line-7", "$ bash-line-8",
                  "$ bash-line-9", "", "", "○1%  ↑10", "❯ next"]

  test "finished bash commits once and clears live viewport":
    var p = initFatPrompt(width = 50, height = 12, window = 1000)
    p.setTokenBar(Usage(promptTokens: 10, totalTokens: 10), window = 1000)
    p.setEditor "next"
    p.beginBash()
    p.pushBashOutput "bash-line-1"
    p.pushBashOutput "bash-line-2"
    p.finishBash()

    let text = p.frameText()
    check text.count("$ bash-line-1") == 1
    check text.count("$ bash-line-2") == 0
    check text.count("  bash-line-2") == 1

  test "receipt is adjacent to item body and next item has one blank row":
    var p = initFatPrompt(width = 50, height = 9, window = 1000)
    p.addTranscriptItem(pmAssistant, "answer", "○10%  ↑100  ↓7")
    p.addTranscriptItem(pmRead, "src/file.nim")
    p.setTokenBar(Usage(promptTokens: 100, totalTokens: 100), window = 1000)
    p.setEditor ""

    p.checkFrame ["", "● answer", "○10%  ↑100  ↓7", "",
                  "r src/file.nim", "", "", "○10%  ↑100", "❯ "]

suite "fat prompt: unicode wrapping":
  proc wrappedRows(body: string): seq[string] =
    var p = initFatPrompt(width = 6, height = 8, window = 1000)
    p.addTranscriptItem(pmUser, body)
    p.setEditor ""
    var seenBody = false
    for row in p.frameText().split("\n"):
      if row.startsWith("❯ ") or row.startsWith("  "):
        seenBody = true
        result.add row
      elif seenBody and row.len == 0:
        break    # blank row ends the transcript body

  test "CJK body wraps two runes per line of width 4":
    # marker prefix '❯ ' is 2 cells; width 6 leaves 4 data cells, so
    # two CJK runes (2 cells each) fit per visual row.
    let rows = wrappedRows("中中中中")
    check rows == @["❯ 中中", "  中中"]

  test "emoji body takes 2 cells per rune":
    let e = Rune(0x1F600).toUTF8
    let rows = wrappedRows(e & e & e)
    # 4 data cells per row, each emoji is 2 cells -> 2 per row
    check rows == @["❯ 😀😀", "  😀"]
