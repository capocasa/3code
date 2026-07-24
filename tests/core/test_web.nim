import std/[unittest, strutils]
import threecode/web

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

  test "capText middle-truncates oversize input":
    let s = "a".repeat(30_000)
    let c = capText(s, 1000)
    check c.len < s.len
    check "truncated" in c
