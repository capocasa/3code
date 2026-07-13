## High-level transcript items for append-only terminal history.
##
## Controllers construct these semantic items and append them through the
## fat-prompt runtime. Formatters in display/tool modules can still build item
## bodies, but this module owns item markers, trimming, and item separators.

import std/[strutils]

import display, fatprompt, types, util

type
  TranscriptKind* = enum
    tiUserPrompt,
    tiAssistant,
    tiTool,
    tiCommand

  TranscriptItem* = object
    kind*: TranscriptKind
    marker*: string
    title*: string
    body*: string
    attachSeparator*: bool

proc trimTranscriptTail(bytes: var string) =
  while bytes.len > 0 and bytes[^1] in {'\r', '\n'}:
    bytes.setLen(bytes.len - 1)

proc normalizeLines(body: string): seq[string] =
  let text = body.strip(chars = {'\r', '\n'})
  if text.len == 0:
    return @[]
  text.replace("\r\n", "\n").replace("\r", "\n").splitLines

proc commandBodyBytes(body: string): string =
  for line in normalizeLines(body):
    if line.len == 0:
      result.add "\r\n"
    elif line.startsWith("  "):
      result.add line & "\r\n"
    else:
      result.add "  " & line & "\r\n"

proc finishItem(bytes: var string; attachSeparator: bool) =
  ## Trim trailing whitespace before the write (append-only-safe). The
  ## inter-item separator is owned by `appendTranscript`; items carry no
  ## trailing separator. (`attachSeparator` is retained on the item type for
  ## construction-call compatibility but no longer appends anything.)
  bytes.trimTranscriptTail()

proc dropLeadingIndent(line: string): string =
  ## Drop a leading two-space indent, skipping any opening SGR run so
  ## styled lines (e.g. `showProfile`) keep their color but lose the
  ## indent the plain-body layout does not want.
  var i = 0
  # Skip a leading CSI sequence (SGR color) if present.
  if i + 1 < line.len and line[i] == '\e' and line[i + 1] == '[':
    i += 2
    while i < line.len and line[i] notin {'@'..'~'}: inc i
    if i < line.len: inc i
  if i + 1 < line.len and line[i] == ' ' and line[i + 1] == ' ':
    result.add line[0 ..< i]
    result.add line[i + 2 .. ^1]
  else:
    result = line

proc plainCommandBodyBytes*(body: string): string =
  ## Like `commandBodyBytes` but without the leading `: title` marker and
  ## with the two-space indent dropped. ANSI styling is preserved so
  ## `showProfile` can mark the active provider/model/reasoning values.
  for line in normalizeLines(body):
    result.add line.dropLeadingIndent() & "\r\n"
  result.finishItem(true)

proc userPromptItem*(line: string): TranscriptItem =
  TranscriptItem(kind: tiUserPrompt, marker: "❯", body: line,
                 attachSeparator: false)

proc assistantItem*(content: string): TranscriptItem =
  TranscriptItem(kind: tiAssistant, marker: "●", body: content,
                 attachSeparator: true)

proc toolItem*(act: Action; res: string; code, idx: int; diff = "";
               elapsedS = -1): TranscriptItem =
  TranscriptItem(kind: tiTool,
                 body: toolTranscriptBytes(act, res, code, idx, diff, elapsedS),
                 attachSeparator: true)

proc commandItem*(name, body: string; ok = true): TranscriptItem =
  TranscriptItem(kind: tiCommand,
                 marker: (if ok: ":" else: "!"),
                 title: name,
                 body: body,
                 attachSeparator: true)

proc emptyAssistantBytes(attachReceipt: bool; receipt = ""): string =
  result.add GreyFg & "empty reply - no content, no tool calls" & Reset
  if attachReceipt and receipt.len > 0:
    result.add "\r\n"
    result.add receipt

proc formatItem*(item: TranscriptItem): string =
  case item.kind
  of tiUserPrompt:
    result = formatUserPromptItem(item.body)
  of tiAssistant:
    if item.body.strip.len == 0:
      result = emptyAssistantBytes(false)
    else:
      result = captureStdoutWrites:
        renderAssistantContent(item.body)
  of tiTool:
    result = item.body
  of tiCommand:
    result.add item.marker
    if item.title.len > 0:
      result.add " " & item.title
    result.add "\r\n"
    result.add commandBodyBytes(item.body)
  result.finishItem(item.attachSeparator)

proc attachReceipt*(bytes: var string; receipt: string; attachSeparator: bool) =
  ## Splice a token receipt row flush below an item body (a single `\r\n`
  ## joins them, no blank between). The inter-item separator after the whole
  ## item is owned by `appendTranscript`, so nothing trailing is appended here.
  if receipt.len == 0:
    return
  bytes.trimTranscriptTail()
  bytes.add "\r\n"
  bytes.add receipt

proc appendItem*(item: TranscriptItem; restoreEditor = true;
                 beforeRepaint: proc() = nil; reserveFooter = true;
                 receipt = "") =
  var bytes = formatItem(item)
  if receipt.len > 0:
    bytes.attachReceipt(receipt, item.attachSeparator)
  commitTranscriptBytes(
    bytes,
    restoreEditor,
    beforeRepaint,
    reserveFooter = reserveFooter)
