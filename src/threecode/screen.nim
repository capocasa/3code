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

  ScreenEventKind* = enum
    seSetMode,
    seSetPromptMode,
    seSetBar,
    seClearBar,
    seSetTicker,
    seClearTicker,
    seSetPendingHint,
    seClearPendingHint

  ScreenEvent* = object
    case kind*: ScreenEventKind
    of seSetMode:
      mode*: ScreenMode
    of seSetPromptMode:
      promptMode*: PromptMode
    of seSetBar:
      barLabel*: string
      barHasGap*: bool
    of seSetTicker:
      ticker*: string
    of seSetPendingHint:
      usage*: Usage
      window*: int
      elapsed*: int
    of seClearBar, seClearTicker, seClearPendingHint:
      discard

proc initScreenState*(): ScreenState =
  ScreenState(mode: smNormal, footer: FooterState(promptMode: pmIdle))

proc setModeEvent*(mode: ScreenMode): ScreenEvent =
  ScreenEvent(kind: seSetMode, mode: mode)

proc setPromptModeEvent*(mode: PromptMode): ScreenEvent =
  ScreenEvent(kind: seSetPromptMode, promptMode: mode)

proc setBarEvent*(label: string; hasGap = false): ScreenEvent =
  ScreenEvent(kind: seSetBar, barLabel: label, barHasGap: hasGap)

proc clearBarEvent*(): ScreenEvent =
  ScreenEvent(kind: seClearBar)

proc setTickerEvent*(ticker: string): ScreenEvent =
  ScreenEvent(kind: seSetTicker, ticker: ticker)

proc clearTickerEvent*(): ScreenEvent =
  ScreenEvent(kind: seClearTicker)

proc setPendingHintEvent*(usage: Usage; window, elapsed: int): ScreenEvent =
  ScreenEvent(kind: seSetPendingHint, usage: usage, window: window,
              elapsed: elapsed)

proc clearPendingHintEvent*(): ScreenEvent =
  ScreenEvent(kind: seClearPendingHint)

proc apply*(s: var ScreenState; ev: ScreenEvent) =
  case ev.kind
  of seSetMode:
    s.mode = ev.mode
  of seSetPromptMode:
    s.footer.promptMode = ev.promptMode
  of seSetBar:
    s.footer.barLabel = ev.barLabel
    s.footer.hasGap = ev.barHasGap
  of seClearBar:
    s.footer.barLabel = ""
    s.footer.hasGap = false
  of seSetTicker:
    s.footer.ticker = ev.ticker
  of seClearTicker:
    s.footer.ticker = ""
  of seSetPendingHint:
    s.footer.pendingHint = PendingHint(active: true, usage: ev.usage,
                                       window: ev.window,
                                       elapsed: ev.elapsed)
  of seClearPendingHint:
    s.footer.pendingHint = PendingHint()

proc setFooterBar*(s: var ScreenState; label: string; hasGap = false) =
  s.apply setBarEvent(label, hasGap)

proc clearFooterBar*(s: var ScreenState) =
  s.apply clearBarEvent()

proc setPendingHint*(s: var ScreenState; usage: Usage; window, elapsed: int) =
  s.apply setPendingHintEvent(usage, window, elapsed)

proc clearPendingHint*(s: var ScreenState) =
  s.apply clearPendingHintEvent()

proc setFooterTicker*(s: var ScreenState; ticker: string) =
  s.apply setTickerEvent(ticker)

proc clearFooterTicker*(s: var ScreenState) =
  s.apply clearTickerEvent()

proc setScreenMode*(s: var ScreenState; mode: ScreenMode) =
  s.apply setModeEvent(mode)

proc setPromptMode*(s: var ScreenState; mode: PromptMode) =
  s.apply setPromptModeEvent(mode)
