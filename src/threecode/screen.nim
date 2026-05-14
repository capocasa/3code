## Screen state for the normal-terminal transcript plus volatile footer.
##
## Rendering still lives in `api.nim` for now. This module gives the prompt,
## token bar, and thinking ticker one explicit state object so the next step
## can route renderer events through a single owner without changing the UX
## away from normal terminal scrollback.

import types

type
  PromptMode* = enum
    pmIdle,
    pmTurnRunning,
    pmBufferedInput

  ScreenMode* = enum
    smNormal,
    smToolStreaming,
    smWizard

  PendingHint* = object
    active*: bool
    usage*: Usage
    window*: int
    elapsed*: int

  FooterState* = object
    promptMode*: PromptMode
    barLabel*: string
    hasGap*: bool
    ticker*: string
    pendingHint*: PendingHint

  ScreenState* = object
    mode*: ScreenMode
    footer*: FooterState

proc initScreenState*(): ScreenState =
  ScreenState(mode: smNormal, footer: FooterState(promptMode: pmIdle))

proc setFooterBar*(s: var ScreenState; label: string; hasGap = false) =
  s.footer.barLabel = label
  s.footer.hasGap = hasGap

proc clearFooterBar*(s: var ScreenState) =
  s.footer.barLabel = ""
  s.footer.hasGap = false

proc setPendingHint*(s: var ScreenState; usage: Usage; window, elapsed: int) =
  s.footer.pendingHint = PendingHint(active: true, usage: usage,
                                     window: window, elapsed: elapsed)

proc clearPendingHint*(s: var ScreenState) =
  s.footer.pendingHint = PendingHint()
