## `resolveSessionProfile`: a resumed session's profile outranks the
## config current, and a profile that no longer resolves (provider or
## model removed since) falls back to the config current instead of
## surfacing as "no provider configured".

import std/[strutils, unittest]
import threecode/[config, library, types]

var
  savedCurrent: string
  savedProviders: seq[ProviderRec]
  savedWhitelist: seq[string]

suite "config: resumed session profile resolution":
  setup:
    savedCurrent = activeCurrent
    savedProviders = activeProviders
    savedWhitelist = providerWhitelist
    activeProviders = @[
      ProviderRec(name: "zai", url: "https://api.z.ai/v1", key: "k",
                  models: @["glm-5.4", "glm-5.3-flash"]),
      ProviderRec(name: "baseten", url: "https://inference.baseten.co/v1",
                  key: "k", models: @["glm-5.3-flash"])]
    activeCurrent = "zai.glm-5.4"
    providerWhitelist = @[]

  teardown:
    activeCurrent = savedCurrent
    activeProviders = savedProviders
    providerWhitelist = savedWhitelist

  test "the session's profile wins over the config current":
    let prof = resolveSessionProfile("baseten.glm-5.3-flash",
                                     "baseten.glm-5.3-flash")
    check prof.name.startsWith("baseten.")

  test "a removed model falls back to the config current":
    check buildProfile("zai.glm-5.3", activeProviders, "").name == ""
    let prof = resolveSessionProfile("zai.glm-5.3", "zai.glm-5.3")
    check prof.name == "zai.glm-5.4"

  test "a removed provider falls back to the config current":
    let prof = resolveSessionProfile("gone.glm-5.4", "gone.glm-5.4")
    check prof.name == "zai.glm-5.4"

  test "an explicit model that does not resolve stays empty":
    check resolveSessionProfile("zai.glm-9.9", "zai.glm-5.4").name == ""
