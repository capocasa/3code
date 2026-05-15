import std/[strutils, unittest]
import threecode/[fatprompt, types]

proc checkFrame(p: FatPrompt; rows: openArray[string]) =
  let expected = @rows.join("\n")
  check p.frameText() == expected

suite "fat prompt frame model":
  test "token bar and editor reserve rows below scrollback":
    var p = initFatPrompt(width = 30, height = 6, window = 1000)
    p.addScrollLine "one"
    p.addScrollLine "two"
    p.addScrollLine "three"
    p.setTokenBar(Usage(promptTokens: 20, totalTokens: 20), window = 1000)
    p.setEditor "hello"

    p.checkFrame ["one", "two", "three", "", "○2%  ↑20", "❯ hello"]

  test "ticker overlays lowest scrollback row without reserving space":
    var p = initFatPrompt(width = 30, height = 6, window = 1000)
    for line in ["one", "two", "three", "four"]:
      p.addScrollLine line
    p.setTicker "thinking..."
    p.setTokenBar(Usage(promptTokens: 20, totalTokens: 20), window = 1000,
                  apiActive = true, spinner = "◐", elapsedS = 7)
    p.setEditor "hello"

    p.checkFrame ["two", "three", "four", "thinking...",
                  "◐  ○2%  ↑20  7s", "❯ hello"]

    p.setTicker ""
    p.checkFrame ["two", "three", "four", "", "◐  ○2%  ↑20  7s",
                  "❯ hello"]

  test "multiline editor grows reserved area and shrinking reveals scrollback":
    var p = initFatPrompt(width = 18, height = 7, window = 1000)
    for line in ["one", "two", "three", "four", "five"]:
      p.addScrollLine line
    p.setTokenBar(Usage(promptTokens: 20, totalTokens: 20), window = 1000)
    p.setEditor "alpha\nbeta"

    p.checkFrame ["three", "four", "five", "", "○2%  ↑20", "❯ alpha",
                  "  beta"]

    p.setEditor "short"
    p.checkFrame ["two", "three", "four", "five", "", "○2%  ↑20",
                  "❯ short"]

  test "wrapped editor height reserves every visual row":
    var p = initFatPrompt(width = 10, height = 7, window = 1000)
    for line in ["one", "two", "three", "four", "five"]:
      p.addScrollLine line
    p.setTokenBar(Usage(promptTokens: 20, totalTokens: 20), window = 1000)
    p.setEditor "abcdefghijk"

    p.checkFrame ["three", "four", "five", "", "○2%  ↑20", "❯ abcdefgh",
                  "  ijk"]

  test "wrapping keeps unicode runes intact":
    var p = initFatPrompt(width = 8, height = 5, window = 1000)
    p.addScrollLine "one"
    p.setTokenBar(Usage(promptTokens: 20, totalTokens: 20), window = 1000)
    p.setEditor "abédefg"

    p.checkFrame ["one", "", "○2%  ↑20", "❯ abédef", "  g"]

  test "token bar always keeps context and only shows nonzero token slots":
    var p = initFatPrompt(width = 40, height = 3, window = 128000)
    p.setTokenBar(Usage(), window = 128000)
    p.setEditor ""
    check tokenBarText(p.tokenBar) == "○0%"

    p.setTokenBar(Usage(promptTokens: 2000, cachedTokens: 500,
                        completionTokens: 25, totalTokens: 2025),
                  window = 128000, apiActive = true, spinner = "●",
                  elapsedS = 3)
    check tokenBarText(p.tokenBar) == "●  ○1%  ↑1.5k  ↻500  ↓25  3s"

  test "bash viewport shows cutoff plus bottom seven while active":
    var p = initFatPrompt(width = 50, height = 13, window = 1000)
    p.addTranscriptItem(pmUser, "run command")
    p.setTokenBar(Usage(promptTokens: 10, totalTokens: 10), window = 1000)
    p.setEditor "next"
    p.beginBash(idx = 4)
    for i in 1 .. 9:
      p.pushBashOutput "bash-line-" & $i

    p.checkFrame ["❯ run command", "", "$ ... 2 lines omitted :show 4 for full",
                  "$ bash-line-3", "$ bash-line-4", "$ bash-line-5",
                  "$ bash-line-6", "$ bash-line-7", "$ bash-line-8",
                  "$ bash-line-9", "", "○1%  ↑10", "❯ next"]

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

    p.checkFrame ["", "", "● answer", "○10%  ↑100  ↓7", "",
                  "r src/file.nim", "", "○10%  ↑100", "❯ "]
