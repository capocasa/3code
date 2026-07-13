---
name: cybernetic-plan
description: The go-to method for implementing anything bigger than a trivial change. A single self-updating plan file (cybernetic-plan.md) holds the context handoff, bounded steps, and execution rules; you work one or more steps per context, update the plan with what you learned, then clear context and resume from the file until every step is done.
---

# Cybernetic Plan

The plan file is the source of truth and the only memory that
survives a context clear. Everything lives in it: the problem, the
map, the steps, and a running "Current state" handoff. You execute
against it, mutate it as you learn, and pass it forward to the next
context like a baton.

## When to use

Default to this for any task with more than ~2 moving parts: a
multi-file refactor, a feature touching several modules, a bug that
needs a fix plus its ripple effects, a cleanup across duplicated
systems. If a task would overflow one context window or benefits
from working in verified stages, use it. Trivial single-file edits
don't need it.

## Setup (do this once, up front)

1. **Orient.** Read the codebase enough to scope the work: the files
   involved, the existing patterns, the order dependencies between
   changes. Don't over-research — you'll re-read specifics as you go.

2. **Write `cybernetic-plan.md`** in the project root. It must
   contain, in this order:

   - **Context** — why this work exists and the shape of the problem.
     Name the concrete code locations (files, functions, line ranges)
     that matter. A fresh-context agent should understand the task
     from this section alone.
   - **Current state** — a running handoff. Start it "not begun" and
     update it after every step. This is the single most important
     section: it's what the next context reads first.
   - **Steps** — an ordered checklist of reasonably bounded work.
     Anywhere from a few up to 20–30 for a large effort. Each step is
     one coherent unit of change (a reroute, a deletion, a decision, a
     test addition) small enough to complete and verify in one context.
     Mark each `[ ]` until done, then `[x]`.

   Keep the plan tight. It's an instrument, not an essay.

## Execution loop

Repeat until every step is checked:

1. **Pick one or more steps** to implement this context. You may do
   several in one pass if they're independent and cheap — but don't
   bundle unrelated work. Read the plan's Current state first to know
   where things stand.

2. **Implement.** Stay in scope: do what the step asks, nothing
   adjacent. Match local style. Read a file before you patch it.

3. **Verify before moving on.** Build, run the relevant tests, run the
   thing. A green build is necessary, not sufficient — confirm the
   behavior the step intended, not just that it compiled.

4. **Update `cybernetic-plan.md`** informed by what the implementation
   taught you. Concretely: check the box(es); rewrite the step's
   description to record what actually happened (a signature changed,
   a caller moved, a test was reshaped, a decision was made and why);
   and update the Current state handoff with anything the next context
   needs. When a step revealed the plan was wrong, fix the plan — don't
   soldier on against a stale checklist.

5. **Commit the step** if the project uses version control and the
   work is self-contained. One commit per step (or per coherent group)
   is preferred over a single end-of-everything dump — it makes review
   and bisection trivial. Short one-line messages. Stage specific
   files; don't `git add -A`.

6. **Clear context when it fills.** Call the context-clear tool with a
   prompt that points back at `cybernetic-plan.md`, summarizes
   progress in two lines, and names the next step to pick up. Do this
   *before* you're forced to — a clean handoff at 70% context beats a
   panicky one at 99%.

## Finishing

When every step is `[x]`:

1. **Thorough review.** Re-read the whole diff against the original
   plan. Confirm each concept has exactly one implementation (no
   leftover duplicates, no half-finished dead code, no silenced
   failures). Check that no step's stated intent was quietly dropped.

2. **Full verification.** Build (including a release/optimized build
   if the project has one) and run the full relevant test matrix. Note
   any suite you couldn't run and why — don't pretend it passed.

3. **Commit to version control** if you haven't been committing per
   step. The final state must be a clean, reviewed, committed tree.

## Step sizing

A good step is one you can finish and verify in a single context
without rush. Heuristics:

- **Too big:** "refactor the rendering layer." Split it.
- **Too small:** "rename a variable." Fold it into an adjacent step,
  or batch several trivial renames into one "cleanup" step.
- **Right:** "route caller X through builder Y; add a test that the
  output matches builder Y for input Z."

Decision-only steps (no code, just a choice that constrains later
steps) are valid and valuable — record the decision and its rationale
in the plan so it isn't relitigated.

## Anti-patterns

- **Implementing two entangled steps at once** to save a round-trip.
  When one reshapes the other, you've burned context on the wrong shape.
- **Skipping the plan update** because "it's obvious." It isn't, to
  the next context. The handoff is the deliverable.
- **Editing the checklist to match broken behavior** instead of fixing
  the behavior. The plan serves the code, not the other way around.
- **Clearing context mid-step.** Finish and verify first; the loop's
  whole premise is that each handoff is a clean, working state.
- **Leaving known-failing tests** because they were "already failing."
  If your work touches their domain, fix them or note them explicitly.
