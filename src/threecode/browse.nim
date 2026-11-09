## Browser-backed rendering for `web_fetch` (the `browserfetch` setting).
##
## One headless Chrome per machine, one tab per fetch:
##
## - The browser is a singleton: a dedicated Chrome with its own throwaway
##   profile under the 3code data dir (never the user's real profile),
##   listening on 127.0.0.1:9223. The first 3code that needs it launches
##   the browser in its own process group (`poDaemon`), so it survives that
##   instance and every later 3code reuses it over the debug port.
## - Each fetch creates a tab via `PUT /json/new?url=...` (Chrome creates
##   and navigates in one step), reads `document.body.innerText` over the
##   tab's DevTools websocket until two consecutive reads agree, then
##   closes the tab via `/json/close`. No Page-domain event plumbing.
## - A launch race between two starting instances is benign: the second
##   Chrome exits on the locked profile, and both proceed against the
##   winner once `/json/version` answers.
##
## The `ws` package is the whole protocol surface here; everything else is
## std. Chrome's stdout/stderr pipes are never drained, so the browser
## runs with `--disable-logging` to stay well under the 64KiB pipe buffer.
##
## The whole module is compile-gated (`browserFetchBuild`, types.nim):
## without `-d:browserFetch` nothing here reaches the binary, not even
## the `ws` import.

import types

when browserFetchBuild:
  import std/[asyncdispatch, httpclient, json, os, osproc, strutils, times, uri]
  import ws
  import util

  const
    BrowserPort = 9223
      ## Fixed debug port shared by every 3code on the machine. Off Chrome's
      ## customary 9222 so a dev-driven browser there never collides.
    BootWaitMs = 15_000
      ## How long to wait for a just-launched Chrome to answer /json/version.
    FetchBudgetMs = 20_000
      ## Wall-clock cap for one tab conversation (connect + settle + read).
    SettlePollMs = 350
    SettleTries = 24
      ## JS-heavy pages keep mutating after load: poll innerText until two
      ## consecutive reads agree (~8s worst case, FetchBudgetMs bounds it).
    ShellSuspectChars* = 200
      ## A plain fetch whose surviving text is shorter than this is presumed
      ## a JS shell (SPA markup with no server-rendered content) and is
      ## redone here when `browserfetch` is on. The ladder lives in
      ## actions.nim.

  proc debugBase(): string = "http://127.0.0.1:" & $BrowserPort

  proc browserAlive(): bool =
    let client = newHttpClient(timeout = 1500)
    defer: client.close()
    try:
      client.getContent(debugBase() & "/json/version").len > 0
    except CatchableError:
      false

  proc chromePath(): string =
    ## First Chrome/Chromium binary found, by platform convention. Raises
    ## IOError listing what was tried so a missing browser is actionable.
    var tried: seq[string]
    when defined(windows):
      tried = @[getEnv("PROGRAMFILES(X86)") / r"Google\Chrome\Application\chrome.exe",
                getEnv("PROGRAMFILES") / r"Google\Chrome\Application\chrome.exe",
                getEnv("LOCALAPPDATA") / r"Google\Chrome\Application\chrome.exe"]
      for p in tried:
        if p.len > 0 and fileExists(p): return p
    elif defined(macosx):
      tried = @["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                expandTilde(
                  "~/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
                "/Applications/Chromium.app/Contents/MacOS/Chromium"]
      for p in tried:
        if p.len > 0 and fileExists(p): return p
    else:
      for name in ["google-chrome-stable", "google-chrome",
                   "chromium-browser", "chromium"]:
        let p = findExe(name)
        if p.len > 0: return p
        tried.add name
    raise newException(IOError,
      "no Chrome/Chromium found for browserfetch (tried: " &
      tried.join(", ") & ")")

  proc ensureBrowser() =
    ## Launch the shared browser if it is not up yet; return once the debug
    ## port answers. Safe to call from any 3code instance at any time.
    if browserAlive(): return
    let profile = userDataRoot() / "browser"
    createDir(profile)
    let bin = chromePath()
    let args = @[
      "--headless=new",
      "--remote-debugging-port=" & $BrowserPort,
      "--user-data-dir=" & profile,
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-gpu",
      "--disable-logging",
      "--log-level=3",
      # headless Chrome stamps "HeadlessChrome" into the UA, which is an
      # instant bot flag for the sites this tier exists for.
      "--user-agent=Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " &
      "(KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36",
    ]
    discard startProcess(bin, args = args, options = {poDaemon})
    let deadline = getTime() + initDuration(milliseconds = BootWaitMs)
    while getTime() < deadline:
      if browserAlive(): return
      sleep 200
    raise newException(IOError,
      "headless browser did not answer on 127.0.0.1:" & $BrowserPort &
      " within " & $(BootWaitMs div 1000) & "s (launched " & bin & ")")

  proc runBounded[T](fut: Future[T]): T =
    ## `waitFor` with a wall-clock cap: pump the dispatcher in slices and
    ## raise on deadline instead of hanging on a stuck tab.
    let deadline = getTime() + initDuration(milliseconds = FetchBudgetMs)
    while not fut.finished:
      if getTime() >= deadline:
        raise newException(IOError,
          "browser fetch exceeded " & $(FetchBudgetMs div 1000) & "s")
      poll(80)
    fut.read

  proc rpc(ws: WebSocket; id: int; methd: string;
           params: JsonNode): Future[JsonNode] {.async.} =
    ## One CDP command and its response. Frames that are not our response
    ## (events, pings) are skipped.
    await ws.send($ %*{"id": id, "method": methd, "params": params})
    while true:
      let (op, data) = await ws.receivePacket()
      if op != Opcode.Text: continue
      let m = parseJson(data)
      if m.hasKey("id") and m["id"].getInt == id:
        return m

  const ReadyExpr =
    "(function(){if(location.href==='about:blank'||" &
    "document.readyState!=='complete')return '';" &
    "var b=document.body;return b?b.innerText:''})()"
    ## Empty until the navigated page finished loading (about:blank is the
    ## pre-navigation state and never counts), then its rendered text.

  proc renderUrl*(url: string): string =
    ## Fetch `url` in a fresh tab of the shared browser and return the
    ## rendered text. Raises IOError (no browser, boot/step timeout,
    ## tab-creation failure, page that never renders text).
    ensureBrowser()
    let client = newHttpClient(timeout = 3000)
    defer: client.close()
    let resp = client.request(debugBase() & "/json/new", HttpPut)
    if resp.code.int div 100 != 2:
      raise newException(IOError, "HTTP " & $resp.code & " creating browser tab")
    let info = parseJson(resp.body)
    let tabId = info{"id"}.getStr
    let wsUrl = info{"webSocketDebuggerUrl"}.getStr
    if tabId.len == 0 or wsUrl.len == 0:
      raise newException(IOError, "browser tab response missing id/websocket url")
    let hardDeadline = getTime() + initDuration(milliseconds = FetchBudgetMs)
    try:
      let ws = runBounded(newWebSocket(wsUrl))
      # /json/new only creates the tab (its ?url= form mangles non-trivial
      # URLs); the navigation itself is the standard Page.navigate call.
      let nav = runBounded(
        rpc(ws, 1, "Page.navigate", %*{"url": url}))
      let navErr = nav{"error"}{"data"}.getStr
      if navErr.len > 0:
        raise newException(IOError, "navigation failed: " & navErr)
      var prev = ""
      for i in 2 .. SettleTries + 1:
        if getTime() >= hardDeadline: break
        let m = runBounded(rpc(ws, i, "Runtime.evaluate",
                               %*{"expression": ReadyExpr,
                                  "returnByValue": true}))
        let exc = m{"result", "exceptionDetails"}
        if exc != nil and exc.kind != JNull:
          raise newException(IOError, "browser evaluate failed: " & $exc)
        let txt = m{"result", "result", "value"}.getStr("")
        if txt.len > 0:
          if txt == prev: break
          prev = txt
        if getTime() + initDuration(
            milliseconds = SettlePollMs) >= hardDeadline: break
        sleep(SettlePollMs)
      if prev.len == 0:
        raise newException(IOError, "page rendered no text (empty body)")
      result = prev
    finally:
      # The tab must die with the fetch even when the conversation failed;
      # closing the target also tears the websocket down from Chrome's side.
      try:
        discard client.request(debugBase() & "/json/close/" & tabId, HttpPut)
      except CatchableError:
        discard
