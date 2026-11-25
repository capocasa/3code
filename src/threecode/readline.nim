## The readline (emacs) keymap for the line editor.
##
## This module owns the default ``[shortcuts]`` table — the command
## names and key bindings every editor session starts with. It is pure
## data on purpose: ``minline`` imports it to seed its dispatch tables,
## ``threecode/vim`` layers vi command mode over the same command
## names, and ``config.nim`` validates user overrides against the
## command vocabulary defined here. The command names mirror GNU
## readline's bindable functions (``cancel``, ``yank-pop``,
## ``isearch-backward``, ...) so bash/readline users can map their
## muscle memory one to one.
##
## The table maps command -> space-separated key list; an empty value
## unbinds. See ``docs/manual.md`` for the user-facing syntax.

import tables

const ReadlineShortcuts* = {
    # ESC and CtrlC cancel the ongoing request even when the line holds
    # a typed draft (the app preserves the draft across the interrupt);
    # at the idle prompt they clear a non-empty line (discarding the
    # text into history) and only cancel when it is empty. Up/Down move
    # by visual row and fall through to history at the boundary;
    # CtrlP/CtrlN are history-only.
    "cancel": "ESC CtrlC",
    "clear": "ESC CtrlC",
    "quit-if-empty": "CtrlD",
    "home": "Home CtrlA",
    "end": "End CtrlE",
    "left": "Left CtrlB",
    "right": "Right CtrlF",
    "word-left": "AltB CtrlLeft",
    "word-right": "AltF CtrlRight",
    "up": "Up",
    "down": "Down",
    "history-previous": "CtrlP",
    "history-next": "CtrlN",
    "backspace": "Backspace",
    "delete": "Delete",
    "insert": "Insert",
    "delete-word-left": "CtrlW",
    "delete-to-boundary-left": "AltH",
    "clear-screen": "CtrlL",
    "suspend": "CtrlZ",
    "complete": "Tab",
    "reverse-complete": "ShiftTab",
    "edit-in-editor": "AltE CtrlX>CtrlE",
    "insert-newline": "ShiftEnter AltEnter",
    "select-left": "ShiftLeft",
    "select-right": "ShiftRight",
    "select-up": "ShiftUp",
    "select-down": "ShiftDown",
    "select-home": "ShiftHome",
    "select-end": "ShiftEnd",
    "select-word-left": "CtrlShiftLeft",
    "select-word-right": "CtrlShiftRight",
    "select-all": "CmdA",
    "select-buffer-start": "CtrlShiftHome",
    "select-buffer-end": "CtrlShiftEnd",
    "buffer-start": "",
    "buffer-end": "",
    "cut": "CtrlX",
    "copy": "AltW",
    "paste": "CtrlV",
    "yank": "CtrlY",
    "yank-pop": "AltY",
    "yank-last-arg": "Alt.",
    "delete-word-right": "AltD CtrlDelete",
    "delete-to-boundary-right": "",
    "delete-to-eol": "CtrlK",
    "delete-to-bol": "CtrlU",
    "transpose-chars": "CtrlT",
    "undo": "Ctrl_ Ctrl/",
    "revert-line": "AltR",
    "isearch-backward": "CtrlR",
    "isearch-forward": "CtrlS",
    "nonincremental-search-backward": "AltP",
    "nonincremental-search-forward": "AltN",
    "history-begin": "Alt<",
    "history-end": "Alt>",
    "transpose-words": "AltT",
    "upcase-word": "AltU",
    "downcase-word": "AltL",
    "capitalize-word": "AltC",
    "set-mark": "Ctrl@ AltSpace",
    "exchange-point-and-mark": "",
    "quoted-insert": "CtrlQ",
    "char-search": "Ctrl]",
    "char-search-backward": "",
    "delete-horizontal-space": "",
    "tab-insert": "",
    # The browser hard-reload analogue: retry the in-flight request now.
    # Kitty-protocol terminals report Ctrl+digit distinctly; legacy
    # terminals fold it into the digit itself (typed as text) or the
    # classic control bytes, so the press stays a harmless no-op there.
    # The app installs the handler.
    "retry": "Ctrl9",
    # Sandbox ask answers, armed only while an ask waits (the handlers
    # gate on the ask gate): fire the matching typed command. Distinct
    # keys only on kitty-protocol terminals; legacy terminals fold
    # Ctrl+digit into the digit itself, the classic control bytes, or
    # on Windows consoles the Ctrl+letter byte, so the presses stay
    # harmless no-ops there and the typed :allow/:deny remain.
    "allow": "Ctrl1",
    "allow-dir": "Ctrl2",
    "deny": "Ctrl4"
  }.toTable

