# Development Guide

## Development process

1. Test results, not actions

The main regression testing works via unit tests. Important: Always test the result- not that something was done. Visually, this means we use the ttty testing termal to render the bytes and check the result, we don't check the bytes themselves.

2. First end to end, then adapt tests

When receiving a bug report, first reproduce the bug without the test suite- start up 3code, use the interactive 'expect' tool or comparable, and do what the bug report says to reproduce the bug. If it's not possible to reproduce the bug, stop, and say so.

When the bug is clearly reproduced, find tests that reflect the bad behavior, and change them to the good behavior, if you find any.

Then develop the fix to reflect the tests.

When receiving a feature request, first develop it by reproducing the behavior end to end- run the full tool with the interactive 'expect' tool or comparable,

## Types of Tests

Any bug report must be reproduced with visual tests before attempting a fix.
For terminal/UI behavior, "visual tests" means interactive PTY tests that drive
the real program and capture full frames. A unit test, command-return assertion,
session-log assertion, raw stdout check, or helper-level test is not an
acceptable primary reproducer for a screen bug. Those checks may be added after
the visual reproducer, but they cannot stand in for it.

Expand the visual test coverage when necessary. Prefer broad shakedown tests
over one-off regression tests:

1. Add or update the main full-frame test so it demonstrates the
   reported bug.
2. If the main shakedown cannot reasonably cover it, add the case to another
   large-scale visual test.
3. Add an individual bug-specific PTY test only as a last resort, and still
   make it interactive and frame-based.
4. Run the test and confirm it fails for the reported screen behavior.
5. Inspect the generated frames or frame artifact so the failure matches what
   a user would see.
6. Only after visual reproduction, change implementation code.
7. Keep the visual regression coverage as the acceptance check for the fix.
8. Be very picky about the DRY rule- do not fix bugs by adding more and more special cases, improve the architecure and eliminate classes of bugs.

Byte-level ANSI tests are acceptable only for narrow low-level helpers. Bugs in
prompt placement, scrollback spacing, token bars, streaming output, buffered
input, caret placement, wizard prompts, hidden/masked input, command handling,
or tool rendering must be captured as visual frames. Prefer tests that send
real keystrokes and verify the frame stream over tests that infer behavior from
internal state.

## Development rules

1. Be religious about the dry rule- never add seperate codepaths for same or similar features, make sure there is a lot of resuse.
2. Use func if you can (no side effects), proc normally, template if you have to, macro if you absolutely have to but discuss first.
3. The architecture and code quality must be top notch. Chose carefully where you make changes.
4. Terminal output is append-only- don't mess with terminal output once formatted, except the defined 'fat prompt' area, which is handled by the 'fat prompt' module.
5. The turn runner acts as controller, and the API calls and tool calls are controller tools. the fat prompt helpers and terminal formatter act as a view layer. We don't really have a traditional model layer except the scrollback- a history of items which can be prompt, reply or tool call- might be considered one. Make sure that seperation of concerns is upheld in this way.
