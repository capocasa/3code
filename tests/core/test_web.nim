import std/[net, os, unittest, strutils]
import zippy
import threecode/web

# A one-shot server that replies with LinkedIn's anti-bot status 999.
# `HttpCode` is `range[0..599]`, so httpclient's `parseResponse` itself
# dies with RangeDefect inside `get` — the regression this suite pins.
type Srv999 = ref object
  listener: Socket
  done: bool

proc serve999(s: Srv999) {.thread.} =
  {.cast(gcsafe).}:
    try:
      var client: Socket
      s.listener.accept(client)
      try:
        while client.recvLine(3000).strip.len > 0: discard
      except CatchableError: discard
      # flags = {}: raise on a client that already hung up, so the outer
      # handler drops the socket instead of std/net's EPIPE retry spin.
      net.send(client, "HTTP/1.1 999 Request Denied\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", flags = {})
      client.close()
    except CatchableError:
      discard
    s.done = true

proc start999(): tuple[url: string, srv: Srv999] =
  let s = Srv999(listener: newSocket())
  s.listener.setSockOpt(OptReuseAddr, true)
  s.listener.bindAddr(Port(0), "127.0.0.1")
  s.listener.listen()
  let (_, port) = s.listener.getLocalAddr()
  var thr: Thread[Srv999]
  createThread(thr, serve999, s)
  result = ("http://127.0.0.1:" & $port.uint16 & "/", s)

const ExaFixture = "Title: Nim Programming Language\nURL: https://nim-lang.org/\nPublished: 2024-01-15\nAuthor: Nim Team\nHighlights:\nNim is a statically typed compiled systems programming language.\nIt combines successful concepts from mature languages like Python, Ada and Modula.\n---\nTitle: Learn Nim in Y Minutes\nURL: https://learnxinyminutes.com/docs/nim/\nPublished: 2023-11-02\nHighlights:\nSingle-page tour of Nim syntax for the impatient.\nCovers procs, types, generics and macros."

suite "web helpers":
  test "decodeEntities named and numeric":
    check decodeEntities("a &amp; b &lt;c&gt; &quot;d&quot; &#39;e&#39;") ==
      "a & b <c> \"d\" 'e'"
    check decodeEntities("fa&ccedil;ade") == "fa&ccedil;ade"  # unknown entity passes through
    check decodeEntities("&#x2014; &#8212;") == "— —"

  test "stripHtml removes script/style/comments":
    let h = """
      <html><head><style>body{color:red}</style>
      <!-- hidden --></head>
      <body><script>alert(1)</script>
      <p>Hello <b>world</b>!</p>
      <p>Second &amp; last.</p>
      </body></html>
    """
    let t = stripHtml(h)
    check "Hello world!" in t
    check "Second & last." in t
    check "alert" notin t
    check "color:red" notin t
    check "hidden" notin t

  test "stripHtml survives invalid UTF-8 (latin-1 byte)":
    # Real-world pages are not always UTF-8; a lone high byte made
    # `unicode.strip` walk off the start of the line (IndexDefect).
    let t = stripHtml("<p>caf\xe9</p>")
    check "caf" in t

  test "decodeBody gunzips and passes plain through":
    let plain = "<p>hello</p>"
    check decodeBody("", plain) == plain
    check decodeBody("gzip", zippy.compress(plain)) == plain
    expect IOError:
      discard decodeBody("br", plain)

  test "stripHtml collapses whitespace and block tags":
    let h = "<div>one</div><div>two</div><br>three"
    let t = stripHtml(h)
    check t.splitLines.len >= 3

  test "parseExaText extracts title / url / snippet":
    let hits = parseExaText(ExaFixture)
    check hits.len == 2
    check hits[0].title == "Nim Programming Language"
    check hits[0].url == "https://nim-lang.org/"
    check "statically typed" in hits[0].snippet
    check "Python, Ada" in hits[0].snippet
    check hits[1].title == "Learn Nim in Y Minutes"
    check hits[1].url == "https://learnxinyminutes.com/docs/nim/"
    check "Single-page tour" in hits[1].snippet

  test "parseExaText tolerates records without Highlights":
    let txt = "Title: Bare\nURL: https://bare.example/\n---\nTitle: Two\nURL: https://two.example/\nHighlights:\nSecond."
    let hits = parseExaText(txt)
    check hits.len == 2
    check hits[0].title == "Bare"
    check hits[0].url == "https://bare.example/"
    check hits[0].snippet == ""
    check hits[1].snippet == "Second."

  test "parseExaText ignores empty leading record":
    let txt = "\n---\nTitle: Only\nURL: https://only.example/"
    let hits = parseExaText(txt)
    check hits.len == 1
    check hits[0].title == "Only"

  test "extractSseData returns payload after data: line":
    let body = "event: message\ndata: {\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"x\"}]}}\n\n"
    let payload = extractSseData(body)
    check payload.startsWith("{")
    check "\"result\"" in payload

  test "extractSseData falls back to whole body when no data: line":
    let body = "{\"plain\": true}"
    check extractSseData(body) == "{\"plain\": true}"

  test "extractSseData handles data: with no space":
    let body = "event: message\ndata:{\"k\":1}\n"
    check extractSseData(body) == "{\"k\":1}"

  test "parseParallelResults extracts title / url / joined excerpts":
    let txt = "{\"results\":[{\"url\":\"https://nim-lang.org/\",\"title\":\"Nim\",\"excerpts\":[\"Line one.\",\"Line two.\"]},{\"url\":\"https://example.com/\",\"title\":\"Other\"}]}"
    let hits = parseParallelResults(txt)
    check hits.len == 2
    check hits[0].title == "Nim"
    check hits[0].url == "https://nim-lang.org/"
    check hits[0].snippet == "Line one. Line two."
    check hits[1].title == "Other"
    check hits[1].url == "https://example.com/"
    check hits[1].snippet == ""

  test "parseParallelResults tolerates missing results array":
    check parseParallelResults("{\"error\":\"x\"}").len == 0
    check parseParallelResults("not json").len == 0

  test "parseBraveResults extracts title / url / description":
    let body = "{\"web\":{\"results\":[{\"title\":\"Brave\",\"url\":\"https://brave.com/\",\"description\":\"A search engine.\"}]}}"
    let hits = parseBraveResults(body)
    check hits.len == 1
    check hits[0].title == "Brave"
    check hits[0].url == "https://brave.com/"
    check hits[0].snippet == "A search engine."

  test "parseBraveResults tolerates missing web object":
    check parseBraveResults("{\"query\":{}}").len == 0
    check parseBraveResults("nope").len == 0

  test "formatHits truncates oversize snippets":
    let long = "x".repeat(2000)
    let hits = @[SearchHit(title: "T", url: "https://u/", snippet: long)]
    let rendered = formatHits(hits)
    check "... [truncated]" in rendered
    check "x".repeat(2000) notin rendered
    let short = formatHits(@[SearchHit(title: "T", url: "", snippet: "brief")])
    check "truncated" notin short

  test "capText middle-truncates oversize input":
    let s = "a".repeat(30_000)
    let c = capText(s, 1000)
    check c.len < s.len
    check "truncated" in c

  test "fetchUrl survives a non-standard status (LinkedIn 999)":
    # httpclient raises RangeDefect inside `get` for statuses >= 600;
    # fetchUrl must surface it as the same IOError a normal non-2xx gets.
    let (url, srv) = start999()
    defer:
      for i in 0 ..< 100:
        if srv.done: break
        sleep(20)
      try: srv.listener.close() except CatchableError: discard
    try:
      discard fetchUrl(url)
      fail()
    except IOError as e:
      check e.msg == "HTTP 999 fetching " & url
    except RangeDefect:
      fail()
