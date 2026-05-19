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
  bytes.trimTranscriptTail()
  if attachSeparator:
    bytes.add "\r\n\r\n"

proc stripAnsiCsi(line: string): string =
  var i = 0
  while i < line.len:
    if line[i] == '\e' and i + 1 < line.len and line[i + 1] == '[':
      i += 2
      while i < line.len and line[i] notin {'@'..'~'}:
        inc i
      if i < line.len:
        inc i
    else:
      result.add line[i]
      inc i

proc plainCommandBodyBytes*(body: string): string =
  for line in normalizeLines(body):
    let plain = line.stripAnsiCsi()
    if plain.startsWith("  "):
      result.add plain[2 .. ^1] & "\r\n"
    else:
      result.add plain & "\r\n"
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
  result.add GreyFg & "  (empty reply — no content, no tool calls)" & Reset
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

proc appendItem*(item: TranscriptItem; restoreEditor = true;
                 beforeRepaint: proc() = nil; reserveFooter = true;
                 prefixBoundary = false) =
  var bytes = formatItem(item)
  if prefixBoundary:
    bytes = "\r\n" & bytes
  commitTranscriptBytes(
    bytes,
    restoreEditor,
    beforeRepaint,
    reserveFooter = reserveFooter,
    transcriptOwnsSpacing = true)
