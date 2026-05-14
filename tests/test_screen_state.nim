import std/unittest
import threecode/[api, screen, types]

suite "screen state":
  test "events reduce to visible footer state":
    var s = initScreenState()
    s.apply setModeEvent(smToolStreaming)
    s.apply setPromptModeEvent(pmTurnRunning)
    s.apply setBarEvent("LBL", hasGap = true)
    s.apply setTickerEvent("thinking")

    check s.mode == smToolStreaming
    check s.footer.promptMode == pmTurnRunning
    check s.footer.barLabel == "LBL"
    check s.footer.hasGap
    check s.footer.ticker == "thinking"

    s.apply clearTickerEvent()
    s.apply clearBarEvent()
    s.apply setModeEvent(smNormal)
    check s.mode == smNormal
    check s.footer.ticker == ""
    check s.footer.barLabel == ""
    check not s.footer.hasGap

  test "footer bar and pending receipt live in one state object":
    var s = initScreenState()
    check s.mode == smNormal
    check s.footer.promptMode == pmIdle
    check s.footer.barLabel == ""
    check not s.footer.hasGap
    check not s.footer.pendingHint.active

    setFooterBar(s, "ctx 2%  ↓10", hasGap = true)
    check s.footer.barLabel == "ctx 2%  ↓10"
    check s.footer.hasGap

    let usage = Usage(promptTokens: 100, completionTokens: 10,
                      totalTokens: 110, cachedTokens: 5)
    setPendingHint(s, usage, 2000, 7)
    check s.footer.pendingHint.active
    check s.footer.pendingHint.usage.totalTokens == 110
    check s.footer.pendingHint.window == 2000
    check s.footer.pendingHint.elapsed == 7

    clearPendingHint(s)
    clearFooterBar(s)
    check s.footer.barLabel == ""
    check not s.footer.hasGap
    check not s.footer.pendingHint.active

  test "footer paint helpers update shared screen state":
    let saved = screenState
    defer:
      screenState = saved

    paintBarPrompt("LBL", DimPromptColor)
    check screenState.footer.barLabel == "LBL"
    check not screenState.footer.hasGap

    paintInitialPrompt(Profile())
    check screenState.footer.barLabel == ""
    check not screenState.footer.hasGap
