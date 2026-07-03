import std/[unittest, strutils]
import threecode/web

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

  test "parseSearchHits extracts title / url / snippet":
    let html = """
      <div class="results">
        <div class="result css-x">
          <a class="result-title result-link css-y" href="https://example.com/a" target="_blank" rel="noopener nofollow noreferrer" data-testid="gl-title-link"><h2 class="wgl-title css-z">Title <b>One</b></h2></a>
          <p class="description css-w"><b>Snippet</b> one text.</p>
        </div>
        <div class="result css-x">
          <a class="result-title result-link css-y" href="https://example.com/b?x=1&amp;y=2" data-testid="gl-title-link"><h2 class="wgl-title css-z">Title Two</h2></a>
          <p class="description css-w">Second snippet.</p>
        </div>
      </div>
    """
    let hits = parseSearchHits(html)
    check hits.len == 2
    check hits[0].title == "Title One"
    check hits[0].url == "https://example.com/a"
    check "Snippet one text." in hits[0].snippet
    check hits[1].title == "Title Two"
    check hits[1].url == "https://example.com/b?x=1&y=2"
    check "Second snippet." in hits[1].snippet

  test "capText middle-truncates oversize input":
    let s = "a".repeat(30_000)
    let c = capText(s, 1000)
    check c.len < s.len
    check "truncated" in c
