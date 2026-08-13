## OpenAI subscription auth (ChatGPT Plus/Pro OAuth, the Codex CLI
## public client) for the `chatgpt` provider.
##
## OpenAI's first-party Codex CLI registers a public desktop OAuth
## client (auth.openai.com, OIDC) that third-party agents use to run on
## a user's ChatGPT subscription instead of a metered API key. The
## access token is NOT valid against api.openai.com; it only works
## against the ChatGPT backend (chatgpt.com/backend-api/codex), which
## additionally wants a `chatgpt-account-id` header extracted from the
## token JWT. This module owns the OpenAI specifics: endpoints, client
## id, scopes, the on-disk token store, and the "valid access token,
## refreshing when needed" contract. The OAuth mechanics are generic and
## live in `oauth.nim`; the interactive bits are passed in as procs so
## this module stays UI-free.
##
## Token store: `$XDG_DATA_HOME/3code/auth/openai.json`, mode 0600.
##
## ToS note: the Codex backend is an internal, unversioned surface
## intended for first-party clients; third-party use is the user's
## responsibility.

import std/[atomics, base64, json, os, posix, strutils, times]
import oauth, util

const
  OpenaiAuthorize = "https://auth.openai.com/oauth/authorize"
  OpenaiToken = "https://auth.openai.com/oauth/token"
  ## Public desktop OAuth client metadata (the registration OpenAI's own
  ## Codex CLI and other third-party agents use); not a secret.
  OpenaiClientId = "app_EMoamEEZ73f0CkXaXp7hrann"
  OpenaiScope = "openid profile email offline_access"
  CodexApiUrl* = "https://chatgpt.com/backend-api/codex"
  LoopbackPort = 1455  ## fixed by the client registration
  CallbackPath = "/auth/callback"
  RefreshSkewSec = 120  ## refresh this long before nominal expiry

proc openaiEndpoints*(): OAuthEndpoints =
  ## No RFC 8628 device-code endpoint: OpenAI's headless flow is a custom
  ## JSON API (deviceauth/usercode), so `deviceCode` stays "" and only
  ## the browser flow is offered.
  OAuthEndpoints(authorize: OpenaiAuthorize, token: OpenaiToken,
                 deviceCode: "", clientId: OpenaiClientId,
                 scope: OpenaiScope)

proc tokenPath*(): string =
  userDataRoot() / "auth" / "openai.json"

proc storeTokens*(ts: TokenSet) =
  let path = tokenPath()
  createDir(parentDir(path))
  writeFile(path, $(%*{
    "access_token": ts.accessToken,
    "refresh_token": ts.refreshToken,
    "token_type": ts.tokenType,
    "expires_at": ts.expiresAt}))
  when defined(posix):
    # chmod 0600 — the refresh token is a long-lived credential.
    discard chmod(path.cstring, 0o600)

proc loadTokens*(): TokenSet =
  ## Zero TokenSet when no store exists or it is unreadable.
  let path = tokenPath()
  if not fileExists(path): return
  try:
    let j = parseJson(readFile(path))
    result.accessToken = j{"access_token"}.getStr
    result.refreshToken = j{"refresh_token"}.getStr
    result.tokenType = j{"token_type"}.getStr("Bearer")
    result.expiresAt = j{"expires_at"}.getInt(0)
  except CatchableError:
    discard

proc clearTokens*() =
  let path = tokenPath()
  if fileExists(path): removeFile(path)

proc hasTokens*(): bool =
  loadTokens().refreshToken != ""

proc accountIdFromJwt(token: string): string =
  ## `chatgpt_account_id` claim from the access-token JWT (the Codex
  ## backend keys the subscription to it). The claim lives under the
  ## namespaced `https://api.openai.com/auth` object. "" when absent or
  ## the token is not a JWT.
  let parts = token.split('.')
  if parts.len != 3: return ""
  var payload: string
  try:
    payload = base64.decode(parts[1].replace('-', '+').replace('_', '/') &
      repeat('=', (4 - parts[1].len mod 4) mod 4))
  except CatchableError:
    return ""
  let j = try: parseJson(payload) except CatchableError: return ""
  j{"https://api.openai.com/auth"}{"chatgpt_account_id"}.getStr("")

proc accountId*(): string =
  ## Account id for the stored token ("" when logged out).
  accountIdFromJwt(loadTokens().accessToken)

proc loginBrowser*(openUrl: proc(url: string) {.gcsafe.},
                   showUrl: proc(url: string) {.gcsafe.};
                   cancelFlag: ptr Atomic[bool] = nil): TokenSet =
  ## PKCE browser flow on the fixed loopback port 1455. `openUrl` tries
  ## to launch a browser; `showUrl` prints the URL for manual copy.
  ## Listen starts before either runs so a fast redirect cannot race an
  ## unbound port. Raises OAuthError on failure or when `cancelFlag` is
  ## set.
  let ep = openaiEndpoints()
  let verifier = newPkceVerifier()
  let state = newPkceVerifier()[0 ..< 24]
  let redirectUri = "http://localhost:" & $LoopbackPort & CallbackPath
  let url = browserAuthUrl(ep, redirectUri, state, pkceChallenge(verifier),
    extra = [("id_token_add_organizations", "true"),
             ("codex_cli_simplified_flow", "true"),
             ("originator", "3code")])
  let code = awaitLoopbackCode(LoopbackPort, state, cancelFlag = cancelFlag,
    onListening = proc() {.gcsafe.} =
      showUrl(url)
      openUrl(url))
  if cancelFlag != nil and cancelFlag[].load(moRelaxed):
    raise newException(OAuthError, "cancelled")
  exchangeCode(ep, code, redirectUri, verifier)

proc accessToken*(): string {.gcsafe.} =
  ## A valid access token for the ChatGPT Codex backend, refreshing and
  ## re-storing when within RefreshSkewSec of expiry. Returns "" when no
  ## subscription login exists. Raises OAuthError when the stored grant
  ## is dead (refresh rejected) — that means "log in again".
  var ts = loadTokens()
  if ts.accessToken == "": return ""
  if ts.expiresAt > 0 and epochTime().int64 >= ts.expiresAt - RefreshSkewSec:
    if ts.refreshToken == "": return ""
    ts = refreshTokens(openaiEndpoints(), ts.refreshToken)
    storeTokens(ts)
  ts.accessToken

proc subscriptionTokenFor*(provider: string): string =
  ## Resolver merged into `config.subscriptionTokenForImpl` at startup.
  ## `chatgpt` is the subscription twin alongside an API-key `openai`.
  ## The token only ever goes to chatgpt.com (config resolves the
  ## provider url separately, and api.nim pins https).
  case provider.toLowerAscii
  of "chatgpt": accessToken()
  else: ""
