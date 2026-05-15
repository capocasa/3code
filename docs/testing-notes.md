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

Remaining byte-oriented tests are legacy/local-helper coverage:

- `tests/test_golden.nim`: legacy renderer helper byte snapshots for markdown,
  receipts, and tool banners. These are useful for spotting formatting churn,
  but they do not validate fat-prompt behavior.
- `tests/test_render.nim`: markdown live-vs-replay byte parity. This protects
  the markdown formatter only; terminal layout acceptance must come from visual
  frame tests.
- `tests/test_minline.nim`: editor helper byte strings and grid checks. These
  remain useful for input editing mechanics, but the editor's placement inside
  the terminal belongs to PTY visual tests.
- `tests/test_streaming.nim` and `tests/test_streaming_view.nim`: legacy
  streaming-output timing/viewport helper checks. They do not prove that live
  bash output is compatible with the fat prompt while the editor is active.
