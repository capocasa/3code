# Terminal Rendering Design

This document is the source of truth for the interactive terminal UI. It
overrides the current implementation when the implementation disagrees with it.

## Core Model

`3code` is a regular CLI application with a fat prompt at the end of the
scrollback.

The scrollback must behave like normal terminal scrollback. Model output, tool
output, user echoes, status messages, and final answers are ordinary scrollback
content. If the user scrolls up in the terminal, that content is visible. When
`3code` exits, that content remains visible in the terminal buffer.

The prompt is implemented more like a small TUI, but its position is relative
to the end of the scrollback buffer. It is not a separate full-screen
alternate-screen UI. It is the live bottom chrome attached to normal
scrollback.

## Fat Prompt

The fat prompt consists of these visual regions, from top to bottom:

1. Optional thinking ticker, one line.
2. Token bar, one line.
3. Prompt editor area, one or more lines.

The token bar and prompt editor area reserve real space below the scrollback.
They must never overwrite, hide, or replace scrollback content. The lowest
scrollback line must always be above all required token bar and prompt editor
lines, whether the app is idle, waiting for an API call, running tools, or
accepting buffered input.

The thinking ticker is different. It does not reserve its own space. When
visible, it overwrites the lowest visible scrollback line above the token bar.
When hidden, that scrollback line is shown normally again. The ticker must never
cause the token bar or prompt editor to move into scrollback space.

The token bar preserves the existing product behavior, even if the current
implementation is replaced:

- during an API call it shows a spinner and API-call timer,
- it always shows context percentage,
- it shows input tokens when greater than zero,
- it shows cache tokens when greater than zero,
- it shows output tokens when greater than zero.

## Prompt Area

The prompt editor area is always active while the application is interactive.
The user can type during API calls, tool calls, token bar updates, and thinking
ticker updates.

The editor area can occupy multiple visual lines because of explicit multiline
input, terminal wrapping, history navigation, prefilled residual text, or a
submit marker. Its reserved height is the current rendered editor height, not a
fixed one-line assumption.

Whenever the editor height grows, the scrollback must move upward to make room.
Whenever the editor height shrinks, the scrollback must move back downward and
reveal the scrollback lines that were displaced. This movement is part of the
fat prompt layout, not an output side effect.

The visible caret belongs only to the prompt editor area. No update outside the
editor may leave a visible caret elsewhere. If the real terminal caret cannot
be made stable under concurrent rendering, the implementation may hide the real
caret and draw a simulated caret inside the editor. The user-facing contract is
that the caret is visually anchored to the editor and typing always affects the
editor.

## Rendering Ownership

Terminal rendering is a shared concurrent system:

- keystrokes redraw the prompt editor,
- token usage and API timers redraw the token bar,
- reasoning updates redraw the thinking ticker,
- API and tool output append to scrollback,
- prompt height changes move the scrollback boundary.

These operations must be concurrent and must not disturb each other.

The implementation must have one owner for terminal layout. Individual features
must not independently issue cursor movement, screen clearing, scroll-region
changes, or footer repaint sequences that can conflict with other features.

Valid render operations are:

- append ordinary content to scrollback,
- set or clear the thinking ticker,
- set the token bar text,
- mutate the editor buffer or cursor,
- recompute and apply fat prompt layout,
- render one atomic frame containing all changed regions.

Invalid render operations are:

- clearing from the prompt row as a way to make room for output,
- replaying tool output to repair a footer,
- painting token bars with relative cursor guesses,
- allowing tool/API output to write into any reserved token bar or editor row,
- leaving the terminal cursor outside the editor after a render tick,
- using a scroll-region change that is not coordinated by the layout owner,
- relying on byte-level timing assumptions between independent writers.

## Frame Ticks

The renderer should group concurrent changes into ticks. A tick is the smallest
observable visual update.

A single tick may include, for example:

- several keystrokes applied to the editor,
- one token bar timer update,
- one thinking ticker update,
- a scrollback boundary change because the editor wrapped to a new line.

The result of a tick is one complete terminal frame. Intermediate partial
states inside a tick must not be visible. If synchronized terminal output is
available, it should be used for atomic frame presentation, but correctness
must come from the renderer model rather than from terminal-specific luck.

## Scrollback Contract

Scrollback is append-only except for the one visible line temporarily overlaid
by the thinking ticker.

The token bar and editor reserve physical visual rows. They are live chrome, not
scrollback content. They must not remain in scrollback after exit unless they
have intentionally been converted into ordinary transcript content, such as a
final token receipt.

When the fat prompt grows, existing scrollback moves up. When it shrinks,
existing scrollback moves down. This movement must preserve line order and must
not duplicate, erase, or reorder content.

Tool output is scrollback content. It must appear once. It must not be replayed,
duplicated, or erased as a side effect of footer repair.

Streaming assistant output is scrollback content. It should appear as response
chunks arrive, preserving the existing markdown handling. Markdown rendering may
buffer internally until it has enough content to render correctly, but the UI
contract remains live streaming rather than only end-of-response rendering.

Streaming bash tool output is also scrollback content, with a live bounded
viewport during command execution. While the command is running, display at most
eight lines of bash output: the bottom seven output lines plus a cutoff hint at
the top when older output is hidden. After the tool completes, the final tool
output is committed once to scrollback. It must not be duplicated by viewport
cleanup or footer repair.

All non-bash tool output is scrollback content and follows the same append-once
rule.

## Transcript Items

The transcript is a sequence of items. Each item starts with a leading marker:

- `❯` for user prompts,
- `●` or another response bullet for LLM responses,
- `$` for bash tool calls,
- `r` for read tool calls,
- `w` for write tool calls,
- `p` for patch tool calls,
- other tool-specific bullets where already established.

Each API call ends with a token receipt representing what that API call
returned. The receipt is ordinary transcript content, not live prompt chrome.
There is no blank line between the last output of the API call and its token
receipt.

Between transcript items there is always exactly one newline. That means:

- one newline between a user prompt and the next LLM response,
- one newline between an LLM response and the next tool item,
- one newline between a tool item and the next LLM response,
- one newline after an API token receipt before the next item,
- one newline between the last transcript item and the top of the fat prompt.

There must not be extra blank rows inserted as a side effect of spinner setup,
tool viewport setup, receipt rendering, or prompt height changes.

## Exit Contract

On normal exit:

- live prompt chrome is removed or converted into final ordinary prompt state,
- scrollback remains readable,
- terminal modes are restored,
- the terminal cursor is visible,
- no hidden scroll region or bracketed-paste mode remains active.

On interrupt or signal exit, terminal restoration has priority over cosmetic
cleanup.

## Testing Strategy

Low-level isolated tests may assert byte sequences. These are appropriate for
pure emitters such as token bar formatting, ANSI helpers, and narrow rendering
utilities.

Functional visual tests must not rely primarily on byte-sequence assertions.
They must record full terminal frames and analyze the resulting screen states.

The existing expect-style PTY language should remain part of the testing
toolkit, but it must grow a video-like frame recorder:

- every screen-changing update is captured as a full frame,
- frames are grouped by render tick when possible,
- unchanged time is compressed,
- every changed visual state is retained,
- output can be written to a plain text artifact with frame separators.

The artifact should be simple enough to inspect by eye. A failing test should
produce a readable sequence of screens, not only raw escape bytes.

## Functional Test Requirements

The main visual flow test should run a brief full interaction using the stub
provider. It should include:

- startup,
- a normal prompt submission,
- an API wait with spinner/token timer updates,
- buffered typing during the API wait,
- multiline buffered input,
- history navigation or prompt edits that change editor height,
- visible thinking ticker updates,
- multiple tool calls,
- tool output while the editor remains active,
- final assistant content,
- the buffered prompt being submitted after the current turn,
- normal exit.

Assertions must cover whole frames, not only selected substrings. They must
detect:

- prompt rows jumping,
- caret appearing outside the editor,
- token bar overwriting scrollback,
- editor rows overwriting scrollback,
- scrollback lines disappearing when prompt height grows,
- scrollback lines failing to return when prompt height shrinks,
- duplicated tool output,
- random full-screen clears,
- stale ticker text,
- stale token bars,
- transient invalid frames between otherwise valid states.

The test output stream should be acceptable for LLM-assisted and human visual
review: a sequence of full-screen text frames separated by clear delimiters.
The implementation should be adjusted until the recorded frame stream conforms
to this document.

## Migration Rule

Existing byte-level functional tests are fair game for removal or replacement
when they encode the old renderer behavior. Keep byte-level tests only for
isolated low-level rendering functions where bytes are the actual API.

The acceptance target is not "does this byte sequence match an old helper." The
acceptance target is "does every recorded frame satisfy the fat prompt and
scrollback contract."
