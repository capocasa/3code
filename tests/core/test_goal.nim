## Goal mode v1: activation on bare `goal.md` existence, the verdict-line
## contract, the completion rename, the harness-autosent continuation
## marking, and the transcript-only evidence builder. The verdict being a
## text line plus the `goalCheckHook` seam make the whole loop testable
## with canned verdicts and no provider.

import std/[json, os, strutils, tempfiles, unittest]
import threecode/goal
import threecode/api except callModel
import threecode/session
import threecode/types

proc withGoalDir(body: proc (dir: string)) =
  let dir = createTempDir("goal-test-", "")
  defer: removeDir(dir)
  let old = getCurrentDir()
  setCurrentDir(dir)
  defer: setCurrentDir(old)
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

  test "activation ignores goal-completed.md":
    withGoalDir proc (dir: string) =
      writeFile(GoalCompletedName, "done\n")
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

  test "completion renames goal.md to goal-completed.md":
    withGoalDir proc (dir: string) =
      writeFile(GoalFileName, "the goal\n")
      check completeGoal()
      check not goalModeActive()
      check readFile(GoalCompletedName) == "the goal\n"
      check not completeGoal()

  test "completion rename fails cleanly when goal.md is gone":
    withGoalDir proc (dir: string) =
      check not completeGoal()

  test "feedback continuation is marked harness-autosent":
    let msg = goalFeedbackMessage("write the tests")
    check msg{"role"}.getStr == "user"
    check msg{"agentSent"}.getBool(false)
    check "write the tests" in msg{"content"}.getStr
    # The marker never reaches a provider (same strip as flail notes).
    let wire = stripInternalFields(%*[msg])
    check "agentSent" notin $wire
    # The persisted session renders it `user +agent`, so replay shows a `»`
    # item instead of a user echo.
    var session: Session
    check "user +agent" in renderSession(session, %*[msg])

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
       "content": "compiled fine\nsecond line"},
      {"role": "tool", "tool_call_id": "c2", "content": "wrote 1 bytes"},
      {"role": "assistant", "content": "All done, I promise."}
    ]
    let ev = buildGoalEvidence(msgs)
    check "nim c src/x.nim" in ev
    check "compiled fine" in ev
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
      check readFile(GoalFileName) == "make it so\n"

  test "refuses to clobber a live goal without force":
    withGoalDir proc (dir: string) =
      discard startGoal("first")
      let r = startGoal("second")
      check not r.ok
      check ":goal!" in r.err
      check readFile(GoalFileName).strip == "first"

  test "force replaces the live goal":
    withGoalDir proc (dir: string) =
      discard startGoal("first")
      check startGoal("second", force = true).ok
      check readFile(GoalFileName).strip == "second"

suite "goal check loop (canned verdicts, no provider)":
  let prof = Profile(name: "stub", family: "glm", model: "stub-model")

  test "satisfied verdict flows through runGoalCheck":
    goalCheckHook = proc (p: Profile, goalText, evidence: string):
        tuple[ok: bool, text: string, err: string] =
      check goalText == "ship it"
      check "evidence line" in evidence
      (true, "looks complete\nVERDICT: SATISFIED", "")
    defer: goalCheckHook = nil
    let r = runGoalCheck(prof, "ship it", "evidence line")
    check r.ok
    check r.verdict.kind == gvkSatisfied

  test "feedback verdict carries the verifier's words":
    goalCheckHook = proc (p: Profile, goalText, evidence: string):
        tuple[ok: bool, text: string, err: string] =
      (true, "VERDICT: FEEDBACK: run the tests", "")
    defer: goalCheckHook = nil
    let r = runGoalCheck(prof, "ship it", "")
    check r.ok
    check r.verdict.kind == gvkFeedback
    check r.verdict.feedback == "run the tests"

  test "side-call failure surfaces as ok=false with the reason":
    goalCheckHook = proc (p: Profile, goalText, evidence: string):
        tuple[ok: bool, text: string, err: string] =
      (false, "", "network down")
    defer: goalCheckHook = nil
    let r = runGoalCheck(prof, "ship it", "")
    check not r.ok
    check r.err == "network down"
    check r.verdict.kind == gvkNone

  test "junk verdict output is not satisfaction":
    goalCheckHook = proc (p: Profile, goalText, evidence: string):
        tuple[ok: bool, text: string, err: string] =
      (true, "all good, no verdict line", "")
    defer: goalCheckHook = nil
    let r = runGoalCheck(prof, "ship it", "")
    check r.ok
    check r.verdict.kind == gvkNone
