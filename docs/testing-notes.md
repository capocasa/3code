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

Functional tests should use PTY full-frame recording. Byte-level assertions
should remain only for isolated pure emitters and ANSI-free render helpers.
