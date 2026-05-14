import std/unittest
import threecode/[screen, types]

suite "screen state":
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
