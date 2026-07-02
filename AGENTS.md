# Agent Notes

Before changing terminal rendering, read:

- `.agents/design.md` for the fat prompt architecture and visual contract.
  architecture and module MVC responsibilities.
- `.agents/testing.md` for visual test and frame viewer workflow.
- `.agents/development-guide.md` for agent development and bugfixing rules.
- `.agents/osx-testing.md` for reproducing and verifying macOS fixes via the
  stefani VM and the OSX-only CI workflow.

Bug reports must be reproduced in visual tests before implementation changes.
Prefer expanding the main shakedown or another broad visual test; add narrow
one-off tests only as a last resort.

- Style skills

nim-style-guide
nim-code-organization

## Commits

Commit when a change reaches a sensible, complete state — don't wait to be
asked. Use a short, single-line commit message.
