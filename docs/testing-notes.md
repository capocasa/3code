# Testing Notes

The terminal renderer is moving from relative byte-sequence footer painting to
the fat-prompt frame model in `docs/design.md`.

The following old-paradigm tests were removed or are fair game for replacement
because they pinned relative cursor movement, footer byte streams,
scroll-region repairs, or old bar/prompt lifecycle details instead of
validating complete visual frames:

- `tests/test_footer_bar.nim`: byte-level bar/footer geometry, below-cursor
  footer repaint, and old prompt pairing behavior.
- `tests/test_footer_lifecycle.nim`: end-to-end byte replay of the old sliding
  footer lifecycle.
- `tests/test_footer_receipt.nim`: old receipt placement tied to
  submit-transition byte sequences.
- `tests/test_footer_resize.nim`: old footer wrap/reflow byte emitter behavior.
- `tests/test_footer_resume.nim`: old resume bar byte shape.
- `tests/test_footer_spinner.nim`: old three-row spinner/footer byte sequences.
- `tests/test_input_layout.nim`: old input-thread/footer relative row
  assumptions and production byte helpers.
- `tests/test_screen_state.nim`: old volatile footer reducer shape.
- `tests/test_streaming_markdown.nim`: live markdown tests coupled to old
  footer painting.

The behaviors these tests were trying to protect should be reintroduced as
frame-model tests:

- token bar content and formatting in isolation,
- token receipt after every API call,
- streaming markdown response rendering,
- bounded live bash output viewport,
- append-once tool output,
- prompt editor rows always occupying the bottom reserved area,
- thinking ticker overlaying only the lowest scrollback row,
- no duplicated transcript content,
- no random clears or transient invalid frames,
- terminal cleanup on normal and signal exit.

Functional tests should use PTY full-frame recording. Byte-level assertions are
legacy unless the bytes are the actual public API of an isolated pure helper.
They must not be used to accept or reject fat-prompt behavior. A passing byte
test is only a local helper check; the visual-frame tests are the acceptance
tests for terminal behavior.

Removed during the fat-prompt integration pass:

- `tests/test_api_pure.nim` byte assertions for
  `anchoredEditorFooterBytes`: these checked scroll-region and cursor escape
  substrings. They were intentionally removed because they blessed another
  byte-level footer strategy instead of proving the user-visible invariant.
  The behavior belongs in PTY full-frame tests: the token bar and editor rows
  are reserved, no output appears inside or below the editor area, and editor
  height changes do not leave stale prompt/bar rows.

Removed during the ANSI-test purge:

- `tests/test_golden.nim` and `tests/golden/*.gold`: raw ANSI renderer
  snapshots for markdown, receipts, and tool banners.
- `tests/test_render.nim`: live-vs-replay byte parity and inline markdown ANSI
  assertions.
- `tests/test_minline.nim` atomic redraw / DEC 2026 byte assertions, colored
  prompt byte-grid checks, and bracketed-paste cleanup byte checks.
- `tests/test_util_extra.nim` ANSI-specific `visibleWidth`, `wrapAnsi`, and
  inline-markdown style-code assertions.

Remaining terminal-byte handling in `tests/tty_expect.nim` is harness plumbing:
it parses escape sequences to build full visual frames and recognizes DEC 2026
sync markers to avoid recording half-painted ticks. It is not acceptance
coverage for renderer behavior.

Remaining non-visual tests are local helper checks only. They may validate pure
text parsing, editor editing behavior, wrapping counts, token formatting, and
tool/result data. They must not bless terminal layout, cursor movement,
prompt/footer stability, ANSI paint sequences, or screen cleanup. Those belong
to PTY visual-frame tests and reviewable `tests/output/tty/.../frames.txt`
artifacts.
