## xAI subscription auth (SuperGrok / X Premium+ OAuth) for the xai
## provider.
##
## xAI exposes a public desktop OAuth surface (auth.x.ai, OIDC) that
## third-party coding agents use to run on a user's SuperGrok
## subscription instead of metered API keys. This module owns the xAI
## specifics: endpoints, client id, scopes, the on-disk token store, and
## the "valid access token, refreshing when needed" contract. The OAuth
## mechanics themselves are generic and live in `oauth.nim`; the
## interactive bits (open browser / show device code) are passed in as
## procs so this module stays UI-free.
##
## Token store: `$XDG_DATA_HOME/3code/auth/xai.json`, mode 0600. The
## bearer it vends must only ever go to api.x.ai; `accessToken` enforces
## that by refusing any other host.

import std/[atomics, json, os, posix, strutils, times]
import oauth, util

const
  XaiAuthorize = "https://auth.x.ai/oauth2/authorize"
  XaiToken = "https://auth.x.ai/oauth2/token"
  XaiDeviceCode = "https://auth.x.ai/oauth2/device/code"
  ## Public desktop OAuth client metadata (the same registration the
  ## `grok` CLI and other third-party agents use); not a secret.
  XaiClientId = "b1a00492-073a-47ea-816f-4c329264a828"
  XaiScope = "openid profile email offline_access grok-cli:access api:access"
  XaiApiHost* = "api.x.ai"
  LoopbackPort = 56121
  RefreshSkewSec = 120  ## refresh this long before nominal expiry

proc xaiEndpoints*(): OAuthEndpoints =
  OAuthEndpoints(authorize: XaiAuthorize, token: XaiToken,
                 deviceCode: XaiDeviceCode, clientId: XaiClientId,
                 scope: XaiScope)

proc tokenPath*(): string =
  userDataRoot() / "auth" / "xai.json"

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
    # chmod 0600 — the refresh token is a long-lived credential.
    discard chmod(tmp.cstring, 0o600)
  moveFile(tmp, path)

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
  except CatchableError as e:
    debugOut "xai token store corrupt (re-login): " & e.msg
    result = TokenSet()

proc clearTokens*() =
  let path = tokenPath()
  if fileExists(path): removeFile(path)

proc hasTokens*(): bool =
  loadTokens().refreshToken != ""

proc loginBrowser*(openUrl: proc(url: string) {.gcsafe.},
                   showUrl: proc(url: string) {.gcsafe.};
                   cancelFlag: ptr Atomic[bool] = nil): TokenSet =
  ## PKCE browser flow. `openUrl` tries to launch a browser; `showUrl`
  ## prints the URL for manual copy. Listen starts before either runs so
  ## a fast redirect cannot race an unbound port. Raises OAuthError on
  ## failure or when `cancelFlag` is set.
  let ep = xaiEndpoints()
  let verifier = newPkceVerifier()
  let state = newPkceVerifier()[0 ..< 24]
  let redirectUri = "http://127.0.0.1:" & $LoopbackPort & "/callback"
  let url = browserAuthUrl(ep, redirectUri, state, pkceChallenge(verifier))
  let code = awaitLoopbackCode(LoopbackPort, state, cancelFlag = cancelFlag,
    onListening = proc() {.gcsafe.} =
      showUrl(url)
      openUrl(url))
  if cancelFlag != nil and cancelFlag[].load(moRelaxed):
    raise newException(OAuthError, "cancelled")
  exchangeCode(ep, code, redirectUri, verifier)

proc loginDevice*(showCode: proc(url, userCode: string)): TokenSet =
  ## RFC 8628 device flow for headless hosts. `showCode` presents the
  ## verification URL and user code; this proc then polls until the user
  ## approves, the code expires, or xAI returns a terminal error.
  let ep = xaiEndpoints()
  let j = requestDeviceCode(ep)
  let deviceCode = j{"device_code"}.getStr
  let userCode = j{"user_code"}.getStr
  let verifyUrl = j{"verification_uri_complete"}.getStr(
                    j{"verification_uri"}.getStr)
  if deviceCode == "" or verifyUrl == "":
    raise newException(OAuthError, "unexpected device-code response")
  showCode(verifyUrl, userCode)
  var interval = j{"interval"}.getInt(5)
  let deadline = epochTime() + j{"expires_in"}.getInt(600).float
  while epochTime() < deadline:
    sleep(max(interval, 1) * 1000)
    try:
      return pollDeviceToken(ep, deviceCode)
    except OAuthError as e:
      case pendingError(e)
      of "authorization_pending": discard
      of "slow_down": interval += 5
      else: raise
  raise newException(OAuthError, "device code expired before approval")

proc accessToken*(): string {.gcsafe.} =
  ## A valid access token for api.x.ai, refreshing and re-storing when
  ## within RefreshSkewSec of expiry. Returns "" when no subscription
  ## login exists. Raises OAuthError when the stored grant is dead
  ## (refresh rejected) — that means "log in again".
  var ts = loadTokens()
  if ts.accessToken == "": return ""
  if ts.expiresAt > 0 and epochTime().int64 >= ts.expiresAt - RefreshSkewSec:
    if ts.refreshToken == "": return ""
    ts = refreshTokens(xaiEndpoints(), ts.refreshToken)
    storeTokens(ts)
  ts.accessToken

proc subscriptionTokenFor*(provider: string): string =
  ## Resolver installed as `config.subscriptionTokenForImpl` at startup.
  ## Eligible names: `xai` (legacy oauth-as-xai configs) and `supergrok`
  ## (subscription twin alongside an API-key `xai`). The token is only
  ## ever sent to api.x.ai (config resolves the provider url separately,
  ## and api.nim pins https), but belt-and-braces: refuse anything else.
  case provider.toLowerAscii
  of "xai", "supergrok": accessToken()
  else: ""
