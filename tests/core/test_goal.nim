## Goal mode v1: activation on bare `goal.md` existence, the verdict-line
## contract, the completion rename, the harness-autosent continuation
## marking, and the transcript-only evidence builder. The verdict being a
## text line plus the `goalCheckHook` seam make the whole loop testable
## with canned verdicts and no provider.

import std/[json, os, osproc, sequtils, strutils, tempfiles, unittest]
import threecode/goal
import threecode/display
import threecode/util except dumpIssue
import threecode/api except callModel
import threecode/session
import threecode/types
import threecode/turns
import threecode/fatprompt

proc sh(cmd: string): bool =
  execCmdEx(cmd).exitCode == 0

proc withGoalDir(body: proc (dir: string)) =
  let dir = createTempDir("goal-test-", "")
  defer: removeDir(dir)
  let old = getCurrentDir()
  setCurrentDir(dir)
  defer: setCurrentDir(old)
  body(dir)

proc withGitRepo(body: proc (dir: string)) =
  ## A committed base file plus a dirty tree: one tracked change and a
  ## couple of untracked files, the shape the verifier's diff feed is
  ## for.
  withGoalDir proc (dir: string) =
    let cfg = "-c user.email=t@t -c user.name=t "
    doAssert sh("git init -q .")
    doAssert sh("git " & cfg & "commit -q --allow-empty -m base")
    writeFile("base.txt", "base\n")
    doAssert sh("git add base.txt")
    doAssert sh("git " & cfg & "commit -qm base-file")
    body(dir)

suite "goal mode":
  test "activation is bare existence of goal.md in the cwd":
    withGoalDir proc (dir: string) =
      check not goalModeActive()
      check buildGoalEvidence(%*[{"role": "user", "content": "hi"}]) ==
        "(no tool calls this turn)"
      writeFile(GoalFileName, "# anything\n")
      check goalModeActive()
      check readGoalText() == "# anything\n"

  test "activation ignores retired goal files":
    withGoalDir proc (dir: string) =
      for retired in [GoalConfirmedName, GoalCancelledName, GoalGivenUpName]:
        writeFile(retired, "done\n")
      check not goalModeActive()

  test "verdict contract: final non-empty line decides":
    check parseVerdict("prose about the repo.\nVERDICT: SATISFIED").kind ==
      gvkSatisfied
    check parseVerdict("VERDICT: SATISFIED\n\n\n").kind == gvkSatisfied
    # Fixed words match case-insensitively; the shape stays strict.
    check parseVerdict("verdict: satisfied").kind == gvkSatisfied
    let fb = parseVerdict("I checked the tree.\nVERDICT: FEEDBACK: tests fail")
    check fb.kind == gvkFeedback
    check fb.feedback == "tests fail"
    let long = parseVerdict(
      "VERDICT: FEEDBACK: goal.md wants tests; none were run this turn")
    check long.kind == gvkFeedback
    check long.feedback == "goal.md wants tests; none were run this turn"

  test "verdict contract: junk last line never satisfies":
    check parseVerdict("Everything is done, trust me.").kind == gvkNone
    check parseVerdict("").kind == gvkNone
    # Trailing punctuation breaks the exact-line contract.
    check parseVerdict("VERDICT: SATISFIED.").kind == gvkNone
    # A verdict line buried mid-output is not the final line.
    check parseVerdict("VERDICT: SATISFIED\nthanks, bye").kind == gvkNone
    # Feedback with no content after the colon carries nothing to act on.
    check parseVerdict("VERDICT: FEEDBACK:  ").kind == gvkNone
    check parseVerdict("VERDICT: FEEDBACK:").kind == gvkNone

  test "verdict contract: contract words ending the prose line count":
    # The deviation a live verifier made: the verdict terminating its
    # prose line instead of owning a line. It is still the reply's last
    # words, so it is the verdict - refusing it painted a red-x step
    # quoting `VERDICT: SATISFIED` it would not honor, and the goal
    # never retired.
    let pasted = parseVerdict(
      "The diff adds the rows across providers, tests passed. " &
      "Catalog goal shown complete. VERDICT: SATISFIED")
    check pasted.kind == gvkSatisfied
    check stripVerdictLine(
      "The diff adds the rows. VERDICT: SATISFIED") ==
      "The diff adds the rows."
    let fb = parseVerdict("Checked the tree. VERDICT: FEEDBACK: run tests")
    check fb.kind == gvkFeedback
    check fb.feedback == "run tests"
    check stripVerdictLine(
      "Checked the tree. VERDICT: FEEDBACK: run tests") ==
      "Checked the tree."
    # The icon row honors the inline verdict: green check, no contract
    # text on screen.
    let step = goalStepBytes(GoalStep(
      prose: stripVerdictLine("All rows verified. VERDICT: SATISFIED"),
      verdict: parseVerdict("All rows verified. VERDICT: SATISFIED").kind))
    check "\u2713" in step
    check "\u2717" notin step
    check "VERDICT" notin step
    # The marker quoted mid-sentence, not ending the reply, is prose.
    check parseVerdict(
      "I would only write VERDICT: SATISFIED with proof").kind == gvkNone

  test "verdict contract: whitespace inside the contract words is free":
    # Strip the line's ends, match the words case-insensitively, and
    # allow any or no whitespace between them: the spellings a live
    # verifier produces around the fixed contract words.
    for spell in ["VERDICT:SATISFIED", "VERDICT : SATISFIED",
                  "verdict:\tsatisfied", "Verdict:  Satisfied",
                  "VERDICT: SATISFIED   "]:
      check parseVerdict("Work done. " & spell).kind == gvkSatisfied
    check parseVerdict("VERDICT:SATISFIED").kind == gvkSatisfied
    check stripVerdictLine("Work done. VERDICT :SATISFIED") ==
      "Work done."
    let fb = parseVerdict("Checked. verdict:feedback: run tests")
    check fb.kind == gvkFeedback
    check fb.feedback == "run tests"
    check stripVerdictLine("Checked. VERDICT:\tFEEDBACK: run tests") ==
      "Checked."
    # The freedom is between the words, not after them: a satisfied
    # marker that does not end the reply is still prose.
    check parseVerdict(
      "I write VERDICT : SATISFIED only with proof").kind == gvkNone

  test "completion renames goal.md to achieved.md":
    withGoalDir proc (dir: string) =
      writeFile(GoalFileName, "the goal\n")
      check completeGoal()
      check not goalModeActive()
      check readFile(GoalConfirmedName) == "the goal\n"
      check not completeGoal()

  test "completion rename fails cleanly when goal.md is gone":
    withGoalDir proc (dir: string) =
      check not completeGoal()

  test "feedback continuation is marked harness-autosent":
    let msg = goalFeedbackMessage("write the tests")
    check msg{"role"}.getStr == "user"
    check msg{"agentSent"}.getBool(false)
    check msg{"goalSent"}.getBool(false)
    check "write the tests" in msg{"content"}.getStr
    # The markers never reach a provider (same strip as flail notes).
    let wire = stripInternalFields(%*[msg])
    check "agentSent" notin $wire
    check "goalSent" notin $wire
    # The persisted session renders it `user +agent +goal`, so replay
    # shows a `⚑` item instead of a user echo.
    var session: Session
    check "user +agent +goal" in renderSession(session, %*[msg])

  test "kickoff continuation is marked harness-autosent":
    let msg = goalKickoffMessage("ship the feature")
    check msg{"role"}.getStr == "user"
    check msg{"agentSent"}.getBool(false)
    check msg{"goalSent"}.getBool(false)
    let content = msg{"content"}.getStr
    check "ship the feature" in content
    check "Start working toward it now" in content
    # The markers never reach a provider (same strip as flail notes).
    let wire = stripInternalFields(%*[msg])
    check "agentSent" notin $wire
    check "goalSent" notin $wire
    var session: Session
    check "user +agent +goal" in renderSession(session, %*[msg])

  test "kickoff display is the goal text alone":
    # The wire message carries the `Goal armed:` scaffold and the
    # trailing instruction paragraph; the scrollback item shows the
    # flag plus the goal text alone - the byte-shape inverse of the
    # kickoff builder, with the full content as fallback for a
    # hand-edited or foreign message.
    let content = goalKickoffMessage(
      "fix the login bug\n\nthen ship it"){"content"}.getStr
    check kickoffDisplayText(content) == "fix the login bug\n\nthen ship it"
    check kickoffDisplayText("Goal armed: goal.md\n\nshort goal") ==
      "short goal"                      # single-paragraph goal
    check kickoffDisplayText(content) != content
    check kickoffDisplayText("an ordinary steer") == "an ordinary steer"

  test "kickoff witness: the stanza is fed once, never re-fed on resume":
    # `modeKickoffIn` is the resume guard: a conversation that already
    # carries a mode kickoff (any mode, any marker vintage - the
    # `Goal armed:` content lead is the witness) must not be fed the
    # stanza again.
    check not modeKickoffIn(nil)
    check not modeKickoffIn(%*[{"role": "user", "content": "go"}])
    check not modeKickoffIn(%*[
      {"role": "user", "content": "Goal check: keep going.",
       "agentSent": true, "goalSent": true}])  # feedback is not a kickoff
    let marked = %*[goalKickoffMessage("ship the feature")]
    check modeKickoffIn(marked)
    var preMarker = marked[0]
    preMarker.delete("goalSent")          # a session saved before the mark
    check modeKickoffIn(%*[preMarker])
    check modeKickoffIn(%*[cyberKickoffMessage(
      "- [ ] first\n\n## Current state\n\nNot begun.\n")])

  test "the goalNotified latch round-trips through the session file":
    # Once the kickoff stanza reached the model, a resumed session must
    # not feed it again: the latch persists in the session record and
    # restores on load.
    proc loadTmp(text: string): Session =
      let (f, path) = createTempFile("goal-latch-", ".3log")
      f.write text
      f.close()
      defer: removeFile(path)
      result = loadSessionFile(path)[0]
    var session = Session(cwd: ".")
    session.goalNotified = true
    check "goal_notified=1" in renderSession(session, newJArray()).
      splitLines()[0]
    check loadTmp(renderSession(session, newJArray())).goalNotified
    check not loadTmp(renderSession(Session(cwd: "."),
      newJArray())).goalNotified

  test "evidence builder: last turn's tool calls, no model prose":
    let msgs = %*[
      {"role": "system", "content": "sys"},
      {"role": "user", "content": "earlier turn"},
      {"role": "assistant", "content": newJNull(),
       "tool_calls": [{"id": "old", "type": "function",
        "function": {"name": "bash",
          "arguments": "{\"command\":\"echo stale\"}"}}]},
      {"role": "tool", "tool_call_id": "old", "content": "stale"},
      {"role": "user", "content": "do the work"},
      {"role": "assistant", "content": "I will now do the work perfectly.",
       "tool_calls": [
        {"id": "c1", "type": "function",
         "function": {"name": "bash",
           "arguments": "{\"command\":\"nim c src/x.nim\"}"}},
        {"id": "c2", "type": "function",
         "function": {"name": "write",
           "arguments": "{\"path\":\"src/goal.nim\",\"body\":\"x\"}"}}]},
      {"role": "tool", "tool_call_id": "c1",
       "content": "compiled fine\nmiddle noise\ntests: 12/12 green"},
      {"role": "tool", "tool_call_id": "c2", "content": "wrote 1 bytes"},
      {"role": "assistant", "content": "All done, I promise."}
    ]
    let ev = buildGoalEvidence(msgs)
    check "nim c src/x.nim" in ev
    check "compiled fine" in ev
    # The result tail surfaces too: verdict lines (tests, failures)
    # live at the END of command output, and that is the line a
    # toolless verifier must be able to see.
    check "tests: 12/12 green" in ev
    check "write: src/goal.nim (1 bytes)" in ev
    # The turn boundary is the last user message: earlier-turn calls are
    # out of scope, and assistant prose is never evidence.
    check "stale" notin ev
    check "perfectly" notin ev
    check "promise" notin ev

  test "evidence builder: patch digest, missing result, cap":
    let msgs = %*[
      {"role": "user", "content": "go"},
      {"role": "assistant", "content": newJNull(),
       "tool_calls": [{"id": "p1", "type": "function",
        "function": {"name": "patch",
          "arguments": "{\"path\":\"a.nim\",\"edits\":[{\"search\":\"a\"," &
            "\"replace\":\"b\"},{\"search\":\"c\",\"replace\":\"d\"}]}"}}]},
      {"role": "assistant", "content": newJNull(),
       "tool_calls": [{"id": "p2", "type": "function",
        "function": {"name": "bash",
          "arguments": "{\"command\":\"rg goal\"}"}}]},
      {"role": "tool", "tool_call_id": "p2", "content": "src/goal.nim:1"}
    ]
    let ev = buildGoalEvidence(msgs)
    check "patch: a.nim (2 edits)" in ev
    check "rg goal" in ev
    check "src/goal.nim:1" in ev
    check "(no result recorded)" in ev  # p1 has no tool result in the slice
    # Many oversized calls hit the byte cap and the summary says so.
    var big = %*[{"role": "user", "content": "go"}]
    for i in 1 .. 80:
      big.add %*{"role": "assistant", "content": newJNull(),
        "tool_calls": [{"id": "c" & $i, "type": "function",
          "function": {"name": "bash",
            "arguments": "{\"command\":\"echo line " & $i & "\"}"}}]}
      big.add %*{"role": "tool", "tool_call_id": "c" & $i,
        "content": "x".repeat(150) & " out " & $i}
    let capped = buildGoalEvidence(big)
    check capped.len <= EvidenceCapBytes + 200
    check "evidence cap reached" in capped
    check "echo line 80" notin capped

  test "verifier prompt carries goal text and evidence only":
    let p = verifierPrompt("ship it", "bash: ran tests\n  => ok")
    check "ship it" in p
    check "bash: ran tests" in p
    check GoalFileName in p
    # No diff (non-git dir): the section is absent, not an empty header.
    check "diff" notin p

  test "preamble makes the sufficiency deal explicit":
    # "Fully satisfied" plus "do not infer" leaves an honest model no
    # path to SATISFIED on runtime goals; the preamble must state when
    # the inputs are confirmation ENOUGH.
    check "Accept SATISFIED" in VerifierPreamble
    check "do not demand proof" in VerifierPreamble
    # The verdict contract instruction survives the edit.
    check "End with exactly one line" in VerifierPreamble

  test "verifier prompt embeds the diff as a third section":
    let p = verifierPrompt("ship it", "bash: ran tests\n  => ok",
                           " M a.txt\n+changed")
    check "Working-tree diff vs HEAD" in p
    check "+changed" in p
    check p.find("Working-tree diff") > p.find("bash: ran tests")

suite "verifier diff feed":
  test "tracked change and untracked file content both appear":
    withGitRepo proc (dir: string) =
      writeFile("base.txt", "changed\n")
      writeFile("fresh.txt", "brand new\n")
      let d = buildGoalDiff()
      check " M base.txt" in d
      check "+changed" in d
      check "new file: fresh.txt" in d
      check "+brand new" in d

  test "clean tree yields an empty feed":
    withGitRepo proc (dir: string) =
      check buildGoalDiff().strip.len == 0

  test "outside a git repo the feed is empty":
    withGoalDir proc (dir: string) =
      check buildGoalDiff() == ""

  test "a repo with no commits yet lists untracked files, no fatal":
    withGoalDir proc (dir: string) =
      doAssert sh("git init -q .")
      writeFile("first.txt", "hello\n")
      let d = buildGoalDiff()
      check "?? first.txt" in d
      check "new file: first.txt" in d
      check "+hello" in d
      check "fatal" notin d

  test "oversized diff is truncated with a note":
    withGitRepo proc (dir: string) =
      var big = "x\n"
      writeFile("big.txt", big.repeat(6000))
      discard sh("git add big.txt")
      let d = buildGoalDiff()
      check d.len < GoalDiffCapBytes + 200
      check "diff truncated at" in d

  test "many untracked files stop at the elision limit":
    withGitRepo proc (dir: string) =
      for i in 1 .. GoalDiffMaxUntracked + 5:
        writeFile("u" & $i & ".txt", "u\n")
      let d = buildGoalDiff()
      check "more omitted" in d
      check "u30.txt" notin d

suite "startGoal (the :goal writer)":
  test "empty text is a usage error":
    withGoalDir proc (dir: string) =
      let r = startGoal("   ")
      check not r.ok
      check r.err.startsWith("usage")
      check not fileExists(GoalFileName)

  test "writes goal.md, text stripped and newline-terminated":
    withGoalDir proc (dir: string) =
      check startGoal("  make it so  ").ok
      # New arms land in the settings store (.3code/goal).
      check readFile(".3code" / "goal") == "make it so\n"

  test "refuses to clobber a live goal without force":
    withGoalDir proc (dir: string) =
      discard startGoal("first")
      let r = startGoal("second")
      check not r.ok
      check ":goal!" in r.err
      check readFile(".3code" / "goal").strip == "first"

  test "force replaces the live goal":
    withGoalDir proc (dir: string) =
      discard startGoal("first")
      check startGoal("second", force = true).ok
      check readFile(".3code" / "goal").strip == "second"

suite "cancelGoal (the :goal! exit)":
  test "cancel retires goal.md to goal-cancelled.md":
    withGoalDir proc (dir: string) =
      discard startGoal("doomed")
      check cancelGoal().ok
      check not goalModeActive()
      check not fileExists(".3code" / "goal")
      check readFile(".3code" / "goal-cancelled").strip == "doomed"

  test "cancel without a live goal is an error":
    withGoalDir proc (dir: string) =
      let r = cancelGoal()
      check not r.ok
      check r.err == "no goal active"

suite "goal check loop (canned verdicts, no provider)":
  let prof = Profile(name: "stub", family: "glm", model: "stub-model")

  test "satisfied verdict flows through runGoalCheck":
    goalCheckHook = proc (p: Profile, preamble, prompt: string):
        tuple[ok: bool, text: string, err: string] =
      # The seam carries exactly what would go on the wire.
      check preamble == VerifierPreamble
      check "ship it" in prompt
      check "evidence line" in prompt
      check GoalFileName in prompt
      (true, "looks complete\nVERDICT: SATISFIED", "")
    defer: goalCheckHook = nil
    let r = runGoalCheck(prof, goalMode, "ship it", "evidence line", "")
    check r.ok
    check r.verdict.kind == gvkSatisfied

  test "feedback verdict carries the verifier's words":
    goalCheckHook = proc (p: Profile, preamble, prompt: string):
        tuple[ok: bool, text: string, err: string] =
      (true, "VERDICT: FEEDBACK: run the tests", "")
    defer: goalCheckHook = nil
    let r = runGoalCheck(prof, goalMode, "ship it", "", "")
    check r.ok
    check r.verdict.kind == gvkFeedback
    check r.verdict.feedback == "run the tests"

  test "side-call failure surfaces as ok=false with the reason":
    goalCheckHook = proc (p: Profile, preamble, prompt: string):
        tuple[ok: bool, text: string, err: string] =
      (false, "", "network down")
    defer: goalCheckHook = nil
    let r = runGoalCheck(prof, goalMode, "ship it", "", "")
    check not r.ok
    check r.err == "network down"
    check r.verdict.kind == gvkNone

  test "junk verdict output is not satisfaction":
    goalCheckHook = proc (p: Profile, preamble, prompt: string):
        tuple[ok: bool, text: string, err: string] =
      (true, "all good, no verdict line", "")
    defer: goalCheckHook = nil
    let r = runGoalCheck(prof, goalMode, "ship it", "", "")
    check r.ok
    check r.verdict.kind == gvkNone

suite "verifier steps in scrollback":
  test "the check is a dim quote block led by the verdict icon":
    # Only the icon carries the verdict color; the rule and the prose
    # sit in the dim tier. The rule is continuous across wrapped rows,
    # aligned under the icon, and it is a solid box-drawing line, never
    # a punctuation `|`:
    #   ✓ │ this is the
    #     │ verdict text
    let ok = goalStepBytes(GoalStep(prose: "checked.", verdict: gvkSatisfied))
    check ok == "\x1b[32m" & "✓" & Reset & " " & GreyFg & "│ checked." &
      Reset & "\r\n"
    check "\x1b[31m" notin ok
    check "|" notin ok
    let no = goalStepBytes(GoalStep(prose: "checked.", verdict: gvkFeedback))
    check no == "\x1b[31m" & "✗" & Reset & " " & GreyFg & "│ checked." &
      Reset & "\r\n"
    check "\x1b[32m" notin no
    for b in [ok, no]:
      check "VERDICT" notin b

  test "wrapped rows keep one continuous rule under the icon":
    # A long prose wraps; every row after the first indents two spaces
    # so its `│` sits exactly under the first row's rule, and the dim
    # tier spans rule and text alike.
    let words = repeat("word ", 60)
    let b = goalStepBytes(GoalStep(prose: words, verdict: gvkSatisfied))
    let rows = b.split("\r\n").filterIt(it.len > 0)
    check rows.len > 1
    check rows[0].startsWith("\x1b[32m" & "✓" & Reset & " " & GreyFg & "│ ")
    for row in rows[1 ..^ 1]:
      check row.startsWith("  " & GreyFg & "│ ")
      check "\x1b[32m" notin row
      check "|" notin row
    # A note with no verdict reads as not-yet: red ✗, never a green ✓.
    let note = goalStepBytes(GoalStep(prose: "verifier off"))
    check "\x1b[31m✗" in note
    check "✓" notin note

  test "the verdict line is stripped from the reply before display":
    check stripVerdictLine("all done\nVERDICT: SATISFIED") == "all done"
    check stripVerdictLine("notes\nVERDICT: FEEDBACK: run tests") == "notes"
    check stripVerdictLine("VERDICT: SATISFIED") == ""
    # No contract line means nothing to strip.
    check stripVerdictLine("all good, no verdict line") ==
      "all good, no verdict line"

  test "a bare-verdict reply still shows its verdict icon":
    check goalStepBytes(GoalStep(prose: "", verdict: gvkSatisfied)) ==
      "\x1b[32m" & "✓" & Reset
    check goalStepBytes(GoalStep(prose: "", verdict: gvkFeedback)) ==
      "\x1b[31m" & "✗" & Reset

suite "verifier token accounting":
  test "check tokens add to the ledger and the bar, never replace them":
    var session: Session
    session.savePath = ""
    # The turn's own calls are already ledgered (100/20) and the last
    # assistant message carries its inline usage; the check then spends
    # 30 more in, 5 more out.
    session.usage = Usage(promptTokens: 100, completionTokens: 20,
      totalTokens: 120, cachedTokens: 0)
    var messages = %*[
      {"role": "user", "content": "go"},
      {"role": "assistant", "content": "done",
       "usage": {"promptTokens": 100, "completionTokens": 20,
                  "totalTokens": 120, "cachedTokens": 0}}]
    accountVerifierUsage(session, messages,
      Usage(promptTokens: 30, completionTokens: 5, totalTokens: 35), 1_000)
    # The ledger gets the same += a main call's usage gets.
    check session.usage.promptTokens == 130
    check session.usage.completionTokens == 25
    check session.usage.totalTokens == 155
    # The resting bar carries the turn's numbers with the check's added
    # on - not the check's numbers in place of them.
    check fatPromptState.footer.barLabel ==
      contextLabel(130, 1_000) & "  ↑130  ↓25"
    check fatPromptState.footer.restingLabel == contextLabel(130, 1_000)
    # The check's prompt size never reaches the next call's gauge.
    check session.lastPromptTokens == 0

  test "a check that spent nothing changes nothing":
    var session: Session
    session.savePath = ""
    session.usage = Usage(promptTokens: 100, completionTokens: 20,
      totalTokens: 120)
    var messages = %*[{"role": "assistant", "content": "done",
      "usage": {"promptTokens": 100, "completionTokens": 20,
                 "totalTokens": 120}}]
    emitFatPromptEvent setBarEvent("○ 10%")
    accountVerifierUsage(session, messages, Usage(), 1_000)
    check session.usage.totalTokens == 120
    check fatPromptState.footer.barLabel == "○ 10%"

  test "no assistant usage on the wire means ledger-only accounting":
    var session: Session
    session.savePath = ""
    var messages = %*[{"role": "user", "content": "go"}]
    emitFatPromptEvent clearBarEvent()
    accountVerifierUsage(session, messages,
      Usage(promptTokens: 30, completionTokens: 5, totalTokens: 35), 1_000)
    check session.usage.totalTokens == 35
    check fatPromptState.footer.barLabel == ""
