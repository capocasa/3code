## Goal mode v1: activation on bare `goal.md` existence, the verdict-line
## contract, the completion rename, the harness-autosent continuation
## marking, and the transcript-only evidence builder. The verdict being a
## text line plus the `goalCheckHook` seam make the whole loop testable
## with canned verdicts and no provider.

import std/[json, os, osproc, strutils, tempfiles, unittest]
import threecode/goal
import threecode/display
import threecode/util except dumpIssue
import threecode/api except callModel
import threecode/session
import threecode/types

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

  test "completion renames goal.md to goal-confirmed.md":
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
    check "write the tests" in msg{"content"}.getStr
    # The marker never reaches a provider (same strip as flail notes).
    let wire = stripInternalFields(%*[msg])
    check "agentSent" notin $wire
    # The persisted session renders it `user +agent`, so replay shows a `»`
    # item instead of a user echo.
    var session: Session
    check "user +agent" in renderSession(session, %*[msg])

  test "kickoff prompt carries the goal and the same autosent marking":
    let msg = goalKickoffMessage("ship the feature")
    check msg{"role"}.getStr == "user"
    check msg{"agentSent"}.getBool(false)
    check "ship the feature" in msg{"content"}.getStr
    check "Start working toward it now" in msg{"content"}.getStr
    let wire = stripInternalFields(%*[msg])
    check "agentSent" notin $wire
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

suite "cancelGoal (the :goal! exit)":
  test "cancel retires goal.md to goal-cancelled.md":
    withGoalDir proc (dir: string) =
      discard startGoal("doomed")
      check cancelGoal().ok
      check not goalModeActive()
      check not fileExists(GoalFileName)
      check readFile(GoalCancelledName).strip == "doomed"

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
  test "the check renders through the regular response path":
    # The verify glyph leads the first row exactly where `●` leads a
    # reply, and the prose is markdown-rendered by the same walk - raw
    # markdown never reaches the screen.
    let b = goalStepBytes(GoalStep(prose: "before **bold** after"))
    check b.startsWith(AssistantTextStyle & VerifyGlyph & " " & Reset &
      AssistantTextStyle & "before")
    check "**bold**" notin b
    check "\x1b[22m" & AssistantTextStyle & " after" in b
    check GreyFg notin b

  test "the verdict is an icon row, never the contract text":
    let ok = goalStepBytes(GoalStep(prose: "checked.", verdict: gvkSatisfied))
    check "\x1b[32m" & "  ✓" & Reset in ok
    check "VERDICT" notin ok
    let no = goalStepBytes(GoalStep(prose: "checked.", verdict: gvkFeedback))
    check "\x1b[31m" & "  ✗" & Reset in no
    check "VERDICT" notin no
    # A note with no verdict shows the block alone.
    check goalStepBytes(GoalStep(prose: "verifier off")).len > 0
    check "✓" notin goalStepBytes(GoalStep(prose: "verifier off"))

  test "the verdict line is stripped from the reply before display":
    check stripVerdictLine("all done\nVERDICT: SATISFIED") == "all done"
    check stripVerdictLine("notes\nVERDICT: FEEDBACK: run tests") == "notes"
    check stripVerdictLine("VERDICT: SATISFIED") == ""
    # No contract line means nothing to strip.
    check stripVerdictLine("all good, no verdict line") ==
      "all good, no verdict line"

  test "a bare-verdict reply still shows its verdict icon":
    check goalStepBytes(GoalStep(prose: "", verdict: gvkSatisfied)) ==
      "\x1b[32m" & "  ✓" & Reset
