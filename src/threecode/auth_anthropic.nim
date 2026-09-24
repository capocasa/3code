## Claude subscription auth (Claude Pro/Max OAuth, the Claude Code CLI
## public client) for the `claudecode` provider.
##
## Anthropic registers a public PKCE OAuth client for its Claude Code CLI
## (claude.ai/oauth/authorize) whose tokens run on a Claude Pro/Max
## subscription instead of a metered console key. Third-party agents use
## the same registration — same client id, loopback redirect, and a
## non-standard twist: `state` must echo the PKCE verifier, and the token
## endpoint only accepts JSON bodies. Two more wire contracts ride on the
## token: requests must carry `anthropic-beta: oauth-2025-04-20` with a
## Bearer header (x-api-key is rejected), and the system prompt must open
## with the Claude Code line (handled in anthropic.nim, which also owns
## the api.anthropic.com endpoint pinning in api.nim).
##
## This module owns the Anthropic specifics: endpoints, client id, scopes,
## the on-disk token store, and the "valid access token, refreshing when
## needed" contract. The OAuth mechanics are generic and live in
## `oauth.nim`; the interactive bits are passed in as procs so this module
## stays UI-free.
##
## Token store: `$XDG_DATA_HOME/3code/auth/anthropic.json`, mode 0600.
##
## ToS note: the OAuth surface is scoped to Anthropic's own client and
## can change or reject third-party use at any time; that risk is the
## user's, same as the ChatGPT/Codex twin.

import std/[atomics, httpclient, json, os, posix, strutils, times]
import oauth, util

const
  ClaudeAuthorize = "https://claude.ai/oauth/authorize"
  ClaudeToken = "https://console.anthropic.com/v1/oauth/token"
  ## Public desktop OAuth client metadata (the registration Anthropic's
  ## own Claude Code CLI and other third-party agents use); not a secret.
  ClaudeClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  ClaudeScope = "org:create_api_key user:profile user:inference"
  ClaudeApiUrl* = "https://api.anthropic.com/v1"
    ## The subscription token is only valid against api.anthropic.com;
    ## `requestUrl` pins claudecode profiles here regardless of the
    ## configured url.
  LoopbackPort = 54545
  CallbackPath = "/callback"
  RefreshSkewSec = 300  ## refresh this long before nominal expiry

proc claudeEndpoints*(): OAuthEndpoints =
  OAuthEndpoints(authorize: ClaudeAuthorize, token: ClaudeToken,
                 clientId: ClaudeClientId, scope: ClaudeScope)

proc tokenPath*(): string =
  userDataRoot() / "auth" / "anthropic.json"

proc storeTokens*(ts: TokenSet) =
  let path = tokenPath()
  createDir(parentDir(path))
  # Atomic (temp + rename): a crash mid-write must never leave a truncated
  # store, which loadTokens would read as a corrupt login.
  let tmp = path & ".tmp"
  writeFile(tmp, $(%*{
    "access_token": ts.accessToken,
    "refresh_token": ts.refreshToken,
    "token_type": ts.tokenType,
    "expires_at": ts.expiresAt}))
  when defined(posix):
    setFilePermissions(tmp, {fpUserRead, fpUserWrite})
  moveFile(tmp, path)

proc loadTokens*(): TokenSet =
  let path = tokenPath()
  if not fileExists(path): return
  try:
    let j = parseJson(readFile(path))
    result.accessToken = j{"access_token"}.getStr
    result.refreshToken = j{"refresh_token"}.getStr
    result.tokenType = j{"token_type"}.getStr
    result.expiresAt = j{"expires_at"}.getInt(0)
  except CatchableError as e:
    debugOut "anthropic token store corrupt (re-login): " & e.msg
    result = TokenSet()

proc clearTokens*() =
  let path = tokenPath()
  if fileExists(path): removeFile(path)

proc hasTokens*(): bool =
  loadTokens().refreshToken != ""

proc parseTokenJson(body: string): TokenSet =
  ## Token responses are JSON (`{"access_token", "refresh_token",
  ## "expires_in", "token_type"}`); this endpoint rejects form encoding.
  let j = try: parseJson(body) except CatchableError: newJObject()
  if "error" in j:
    raise newException(OAuthError, j["error"].getStr)
  result.accessToken = j{"access_token"}.getStr
  result.refreshToken = j{"refresh_token"}.getStr
  result.tokenType = j{"token_type"}.getStr("Bearer")
  if result.accessToken == "":
    raise newException(OAuthError, "token response had no access_token")
  let ttl = j{"expires_in"}.getInt(0)
  if ttl > 0:
    result.expiresAt = epochTime().int64 + ttl

proc postTokenJson(body: JsonNode): TokenSet =
  let client = newHttpClient(timeout = 30_000, userAgent = "3code",
                             sslContext = bundledSslContext())
  defer: client.close()
  client.headers["Content-Type"] = "application/json"
  let resp = guardedHttp(client.post(ClaudeToken, body = $body), OAuthError,
                         "posting " & ClaudeToken)
  if resp.code.int notin 200..299:
    let j = try: parseJson(resp.body) except CatchableError: newJObject()
    let detail = j{"error"}{"message"}.getStr(j{"error"}.getStr(
      resp.body[0 ..< min(200, resp.body.len)]))
    raise newException(OAuthError,
      "HTTP " & $resp.code.int & " — " & detail)
  parseTokenJson(resp.body)

proc loginBrowser*(openUrl: proc(url: string) {.gcsafe.},
                   showUrl: proc(url: string) {.gcsafe.};
                   cancelFlag: ptr Atomic[bool] = nil): TokenSet =
  ## PKCE browser flow on the fixed loopback port 54545. This client's
  ## flow echoes the PKCE verifier as `state` (checked by the loopback
  ## listener) and wants `code=true` so the consent page issues a code
  ## instead of silently bouncing. `openUrl` tries to launch a browser;
  ## `showUrl` prints the URL for manual copy. Listen starts before
  ## either runs so a fast redirect cannot race an unbound port.
  ## Raises OAuthError on failure or when `cancelFlag` is set.
  let ep = claudeEndpoints()
  let verifier = newPkceVerifier()
  let redirectUri = "http://localhost:" & $LoopbackPort & CallbackPath
  let url = browserAuthUrl(ep, redirectUri, verifier, pkceChallenge(verifier),
    extra = [("code", "true")])
  let code = awaitLoopbackCode(LoopbackPort, verifier, cancelFlag = cancelFlag,
    onListening = proc() {.gcsafe.} =
      showUrl(url)
      openUrl(url))
  if cancelFlag != nil and cancelFlag[].load(moRelaxed):
    raise newException(OAuthError, "cancelled")
  # JSON exchange (not the generic form-encoded one), with the echoed
  # `state` field this endpoint demands.
  var ts = postTokenJson(%*{
    "grant_type": "authorization_code",
    "code": code,
    "redirect_uri": redirectUri,
    "client_id": ClaudeClientId,
    "code_verifier": verifier,
    "state": verifier})
  if ts.refreshToken == "":
    raise newException(OAuthError, "no refresh token from Claude login")
  ts

proc refresh*(refreshToken: string): TokenSet =
  ## JSON refresh; keeps the old refresh token when the response omits
  ## one (no rotation).
  var ts = postTokenJson(%*{
    "grant_type": "refresh_token",
    "refresh_token": refreshToken,
    "client_id": ClaudeClientId})
  if ts.refreshToken == "":
    ts.refreshToken = refreshToken
  ts

proc accessToken*(): string {.gcsafe.} =
  ## A valid access token for api.anthropic.com, refreshing and
  ## re-storing when within RefreshSkewSec of expiry. Returns "" when no
  ## subscription login exists. Raises OAuthError when the stored grant
  ## is dead (refresh rejected) — that means "log in again".
  var ts = loadTokens()
  if ts.accessToken == "": return ""
  if ts.expiresAt > 0 and epochTime().int64 >= ts.expiresAt - RefreshSkewSec:
    if ts.refreshToken == "": return ""
    ts = refresh(ts.refreshToken)
    storeTokens(ts)
  ts.accessToken

proc subscriptionTokenFor*(provider: string): string =
  ## Resolver installed as `config.subscriptionTokenForImpl` at startup.
  ## `claudecode` is the subscription twin alongside an API-key
  ## `anthropic`; legacy `anthropic` configs never carried OAuth, so it
  ## resolves to "" there (re-add as `claudecode` to log in).
  case provider.toLowerAscii
  of "claudecode": accessToken()
  else: ""
