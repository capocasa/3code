# task: debug-systematic

For when something's broken and the path forward isn't obvious. Random
poking is how an hour becomes a day.

## Step 0: reproduce

If you can't reproduce it, you can't fix it. Get to a one-line
incantation that produces the failure on demand. Until you have that,
you're guessing.

If the bug is intermittent: capture state when it happens
(`strace`, logs, screenshots, core dump). Don't lose the artifact
trying to retry.

## Step 1: read the actual error

Read the full error message, slowly. Not the bit that confirms what
you suspect — the whole thing. The line number, the function, the
type, the path. Errors are usually more precise than your reading of
them.

When the error says "X not found" — check spelling, case, and path.
When it says "permission denied" — check who, what, where. When it
says "unexpected token" — check the line *before* the one named.

## Step 2: minimum reproducer

Strip everything that isn't required to trigger the failure. No logic
that doesn't matter, no data that isn't load-bearing, no dependencies
that aren't in the path. The bug shrinks with the reproducer; what's
left is the bug.

This often *is* the fix — the act of stripping reveals the cause.

## Step 3: bisect

If you don't know which change broke it: `git bisect`, or its
manual equivalent. Halve the search space each step. Don't reason —
measure.

If you don't know which input triggers it: halve the input. The line
that broke is in one half or the other; halve again.

If you don't know which dependency: pin everything, then start
unpinning one at a time.

## Step 4: hypothesis → test → result

Write down (mentally is fine):

- **Hypothesis:** "I think it's failing because X."
- **Test:** "If true, doing Y will produce Z."
- **Result:** Y produces what?

If Z, you have a confirmed cause. If not, the hypothesis was wrong —
move on. **Don't change two things at once;** you won't know which
one mattered.

## Step 5: explain it

Out loud, to a duck or the user. Not "here's what's broken" but
"here's why it's broken" — root cause, not symptom. If you can't
state the why in one sentence, you don't have the cause yet.

This is the rubber-duck moment that solves more bugs than any
debugger.

## Anti-patterns

- **Adding error handling around the failure** without understanding
  it. That hides the bug, doesn't fix it.
- **Restarting / clearing cache / reboot** as a primary move.
  Sometimes warranted, but if it works you don't actually know why.
- **Reading 200 lines of stack trace** before reading the bottom of
  the trace where the actual error is.
- **"It works on my machine."** That's data, not a conclusion. What
  differs?

## When to stop and ask

If after ~30 minutes of focused debugging the cause is still opaque,
write up what you know: the failure, the reproducer, what you've
ruled out, the current hypothesis. Either share it (a fresh pair of
eyes catches what you can't) or sleep on it. The pattern matters more
than the breakthrough.

## Reporting

State the root cause in one sentence, the fix in one sentence, and
how you confirmed the fix actually fixes it (not just that the build
passes — that the original failure no longer reproduces).
