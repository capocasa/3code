## Google subscription auth (Gemini CLI / Code Assist OAuth) for the
## `geminicli` provider.
##
## Google's first-party Gemini CLI registers a public desktop OAuth
## client (accounts.google.com, OIDC) that third-party agents use to run
## on a user's Gemini Code Assist free/Pro/Ultra tier instead of a
## metered AI Studio API key. The client ships with a client_secret
## baked into the open-source gemini-cli; it is not a real secret and
## every third-party consumer (CLIProxyAPI, opencode-gemini-auth,
## hermes-agent) embeds the same pair.
##
## The access token is NOT valid against the AI Studio endpoint
## (generativelanguage.googleapis.com rejects it with
## ACCESS_TOKEN_SCOPE_INSUFFICIENT); it only works against the Code
## Assist backend (cloudcode-pa.googleapis.com), which speaks a wrapped
## Gemini-native `v1internal:generateContent` shape, not OpenAI chat
## completions. That transport lives in api.nim; this module owns the
## Google specifics: endpoints, client pair, scopes, the on-disk token
## store, and the "valid access token, refreshing when needed" contract.
## The OAuth mechanics are generic and live in `oauth.nim`; the
## interactive bits are passed in as procs so this module stays UI-free.
##
## Token store: `$XDG_DATA_HOME/3code/auth/google.json`, mode 0600.
##
## ToS note: cloudcode-pa is an internal, unversioned surface intended
## for first-party clients; third-party use is the user's
## responsibility.

import std/[atomics, httpclient, json, os, posix, strutils, times]
import oauth, util

const
  GoogleAuthorize = "https://accounts.google.com/o/oauth2/v2/auth"
  GoogleToken = "https://oauth2.googleapis.com/token"
  ## Desktop OAuth client metadata from the open-source
  ## `@google/gemini-cli` (packages/core/src/code_assist/oauth2.ts).
  ## Installed-application credential; per Google's OAuth docs the
  ## client secret is "obviously not treated as a secret" here:
  ## https://developers.google.com/identity/protocols/oauth2#installed
  GoogleClientId = "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com"
  GoogleClientSecret = "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"
  GoogleScope = "https://www.googleapis.com/auth/cloud-platform " &
                "https://www.googleapis.com/auth/userinfo.email " &
                "https://www.googleapis.com/auth/userinfo.profile"
  CloudCodeApiUrl* = "https://cloudcode-pa.googleapis.com"
  RefreshSkewSec = 120  ## refresh this long before nominal expiry

proc googleEndpoints*(): OAuthEndpoints =
  ## No RFC 8628 device-code endpoint in use: gemini-cli's headless flow
  ## is copy-the-URL, so `deviceCode` stays "" and only the browser flow
  ## is offered.
  OAuthEndpoints(authorize: GoogleAuthorize, token: GoogleToken,
                 deviceCode: "", clientId: GoogleClientId,
                 scope: GoogleScope, clientSecret: GoogleClientSecret)

proc tokenPath*(): string =
  userDataRoot() / "auth" / "google.json"

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
    debugOut "google token store corrupt (re-login): " & e.msg
    result = TokenSet()

proc clearTokens*() =
  let path = tokenPath()
  if fileExists(path): removeFile(path)
  let proj = userDataRoot() / "auth" / "google-project.txt"
  if fileExists(proj): removeFile(proj)

proc hasTokens*(): bool =
  loadTokens().refreshToken != ""

proc accessToken*(): string {.gcsafe.} =
  ## A valid access token for the Code Assist backend, refreshing and
  ## re-storing when within RefreshSkewSec of expiry. Returns "" when no
  ## subscription login exists. Raises OAuthError when the stored grant
  ## is dead (refresh rejected) — that means "log in again".
  var ts = loadTokens()
  if ts.accessToken == "": return ""
  if ts.expiresAt > 0 and epochTime().int64 >= ts.expiresAt - RefreshSkewSec:
    if ts.refreshToken == "": return ""
    ts = refreshTokens(googleEndpoints(), ts.refreshToken)
    storeTokens(ts)
  ts.accessToken

proc resolveProjectId*(token: string): string {.gcsafe.}

proc projectPath(): string =
  userDataRoot() / "auth" / "google-project.txt"

proc storeProjectId*(id: string) =
  ## Persisted beside the token store: Code Assist keys every request's
  ## quota to this project, and re-running loadCodeAssist/onboardUser on
  ## every session start would provision duplicates and add seconds.
  if id == "": return
  let path = projectPath()
  createDir(parentDir(path))
  writeFile(path, id)
  when defined(posix):
    discard chmod(path.cstring, 0o600)

proc projectId*(token = ""): string {.gcsafe.} =
  ## The Code Assist project for the logged-in account: env override,
  ## then the persisted discovery result, then a live
  ## loadCodeAssist/onboardUser round (persisted). "" when logged out
  ## and undiscoverable.
  let envProject = getEnv("GOOGLE_CLOUD_PROJECT")
  if envProject != "": return envProject
  let path = projectPath()
  if fileExists(path):
    let id = readFile(path).strip
    if id != "": return id
  let tok = if token != "": token else: accessToken()
  if tok == "": return ""
  result = resolveProjectId(tok)
  if result != "": storeProjectId(result)

proc subscriptionTokenFor*(provider: string): string =
  ## Resolver merged into `config.subscriptionTokenForImpl` at startup.
  ## `geminicli` is the subscription twin alongside an API-key `google`.
  ## The token only ever goes to cloudcode-pa.googleapis.com (api.nim
  ## pins the host for this provider).
  case provider.toLowerAscii
  of "geminicli": accessToken()
  else: ""

proc loginBrowser*(openUrl: proc(url: string) {.gcsafe.},
                   showUrl: proc(url: string) {.gcsafe.};
                   cancelFlag: ptr Atomic[bool] = nil): TokenSet =
  ## PKCE browser flow. Google registers no fixed loopback port for the
  ## gemini-cli client: any `http://127.0.0.1:<port>` redirect URI is
  ## accepted (gemini-cli binds a random port), so we let the OS pick a
  ## free one. Listen starts before either `openUrl` or `showUrl` runs so
  ## a fast redirect cannot race an unbound port. Raises OAuthError on
  ## failure or when `cancelFlag` is set.
  let ep = googleEndpoints()
  let verifier = newPkceVerifier()
  let state = newPkceVerifier()[0 ..< 24]
  let port = freeLoopbackPort()
  let redirectUri = "http://127.0.0.1:" & $port & "/oauth2callback"
  let url = browserAuthUrl(ep, redirectUri, state, pkceChallenge(verifier),
    extra = [("access_type", "offline"), ("prompt", "consent")])
  let code = awaitLoopbackCode(port, state, cancelFlag = cancelFlag,
    onListening = proc() {.gcsafe.} =
      showUrl(url)
      openUrl(url))
  if cancelFlag != nil and cancelFlag[].load(moRelaxed):
    raise newException(OAuthError, "cancelled")
  exchangeCode(ep, code, redirectUri, verifier)

proc resolveProjectId*(token: string): string {.gcsafe.} =
  ## The Code Assist project id for this account. Code Assist keys quota
  ## to a `cloudaicompanionProject`: accounts that have used Gemini
  ## Code Assist in an IDE already have one; fresh accounts get one
  ## provisioned by `onboardUser` (free tier) or supply their own Google
  ## Cloud project (paid tiers). Mirrors what gemini-cli does on first
  ## run: loadCodeAssist, then onboardUser when no project is bound.
  let client = newHttpClient(timeout = 30_000, userAgent = "3code",
                             sslContext = bundledSslContext())
  defer: client.close()
  client.headers = newHttpHeaders({
    "Authorization": "Bearer " & token,
    "Content-Type": "application/json"})
  let envProject = getEnv("GOOGLE_CLOUD_PROJECT")
  let loadBody = %*{
    "cloudaicompanionProject": (if envProject != "": %envProject else: newJNull()),
    "metadata": {
      "ideType": "IDE_UNSPECIFIED",
      "platform": "PLATFORM_UNSPECIFIED",
      "pluginType": "GEMINI"}}
  let resp = client.post(CloudCodeApiUrl & "/v1internal:loadCodeAssist",
                         body = $loadBody)
  if resp.code.int != 200: return envProject
  let j = try: parseJson(resp.body) except CatchableError: return envProject
  let existing = j{"cloudaicompanionProject"}.getStr("")
  if existing != "": return existing
  if envProject != "": return envProject
  # No project bound: provision the free tier. onboardUser is long-running;
  # poll until done (gemini-cli waits ~5s per poll).
  let tier =
    if j{"allowedTiers"}.kind == JArray and j{"allowedTiers"}.len > 0:
      j["allowedTiers"][0]{"id"}.getStr("free-tier")
    else: "free-tier"
  let onboardBody = %*{
    "tierId": tier,
    "metadata": {
      "ideType": "IDE_UNSPECIFIED",
      "platform": "PLATFORM_UNSPECIFIED",
      "pluginType": "GEMINI"}}
  let op = client.post(CloudCodeApiUrl & "/v1internal:onboardUser",
                       body = $onboardBody)
  if op.code.int != 200: return ""
  var opj = try: parseJson(op.body) except CatchableError: return ""
  for _ in 0 ..< 24:
    if opj{"done"}.getBool(false): break
    let name = opj{"name"}.getStr("")
    if name == "": break
    sleep(5000)
    let poll = client.get(CloudCodeApiUrl & "/v1internal/" & name)
    if poll.code.int != 200: break
    opj = try: parseJson(poll.body) except CatchableError: break
  opj{"response"}{"cloudaicompanionProject"}{"id"}.getStr("")
