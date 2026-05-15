# Development Guide

## Bugfixing

Any bug report must be reproduced with visual tests before attempting a fix.

Expand the visual test coverage when necessary. Prefer broad shakedown tests
over one-off regression tests:

1. Add or update the main PTY/full-frame shakedown test so it demonstrates the
   reported bug.
2. If the main shakedown cannot reasonably cover it, add the case to another
   large-scale visual test.
3. If the behavior needs a different scenario, create another multi-angle
   visual case that exercises several related states.
4. Add an individual bug-specific test only as a last resort.
5. Run the test and confirm it fails for the reported behavior.
6. Only after reproduction, change implementation code.
7. Keep the visual regression coverage as the acceptance check for the fix.

Byte-level ANSI tests are acceptable only for narrow low-level helpers. Bugs in
prompt placement, scrollback spacing, token bars, streaming output, buffered
input, caret placement, or tool rendering must be captured as visual frames.
