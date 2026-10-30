import std/unittest
import threecode/fatprompt/runtime

suite "prompt draft debounce":
  # The draft sidecar save is key-press triggered (armed by `onMutate`) and
  # debounced: it fires only after a sentence completes AND typing has been
  # briefly quiet, so steady typing and mid-sentence pauses write nothing.
  test "save is due only when armed, sentence-complete, and paused":
    check not draftSaveDue(false, 60.0, "a finished sentence.")
    check not draftSaveDue(true, DraftDebounceS - 0.01, "a finished sentence.")
    check draftSaveDue(true, DraftDebounceS, "a finished sentence.")
    check draftSaveDue(true, 60.0, "a finished sentence.")

  test "mid-sentence text is never due, however long the pause":
    check not draftSaveDue(true, 60.0, "half-typed")
    check not draftSaveDue(true, 60.0, "wait, still going,")

  test "an emptied buffer is due so a stale sidecar is cleared":
    check draftSaveDue(true, 60.0, "")
