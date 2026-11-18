## `[settings] limitproviders`: the provider whitelist. Parsing (every
## spelling, every separator), the empty default (no restriction), the
## pick surfaces it gates (profile resolution, the verifier pool,
## completion), and the management surfaces it must NOT gate.

import std/[os, sequtils, strutils, tables, unittest]
import threecode/[config, types, ui, library]

var tmp = getTempDir() / ("3code-test-limitproviders-" &
  $getCurrentProcessId() & ".ini")

proc resetState() =
  providerWhitelist = @[]
  activeProviders = @[]
  activeCurrent = ""
  activeParams = @[]
  removeFile(tmp)

proc writeConfig(body: string) =
  writeFile(tmp, body)

let alpha = ProviderRec(name: "alpha", url: "https://alpha.example",
                        key: "k", models: @["zai/glm-5.2"])
let beta = ProviderRec(name: "beta", url: "https://beta.example",
                       key: "k", models: @["zai/glm-5.2"])

suite "config: limitproviders parsing":
  setup: resetState()
  teardown: resetState()

  test "absent key means no restriction":
    writeConfig("[settings]\ncurrent = \"alpha.zai/glm-5.2\"\n")
    discard tryLoadStateOrEmpty(tmp)
    check providerWhitelist.len == 0
    check providerAllowed("anything-at-all")

  test "comma and whitespace separated names":
    writeConfig(
      "[settings]\nlimitproviders = \"alpha, beta  gamma\"\n")
    discard tryLoadStateOrEmpty(tmp)
    check providerWhitelist == @["alpha", "beta", "gamma"]

  test "alias spellings parse the same":
    for key in ["limit-providers", "limit_providers"]:
      writeConfig("[settings]\n" & key & " = \"alpha\"\n")
      discard tryLoadStateOrEmpty(tmp)
      check providerWhitelist == @["alpha"]

  test "assignment, not accumulation":
    writeConfig(
      "[settings]\nlimitproviders = \"alpha\"\nlimitproviders = \"beta\"\n")
    discard tryLoadStateOrEmpty(tmp)
    check providerWhitelist == @["beta"]

  test "an empty value is a schema error":
    writeConfig("[settings]\nlimitproviders = \"\"\n")
    let (_, _, _, err) = tryLoadStateOrEmpty(tmp)
    check err.contains("limitproviders")

suite "config: limitproviders enforcement":
  setup: resetState()
  teardown: resetState()

  test "selectableProviders narrows the list, activeProviders keeps all":
    writeConfig("[settings]\nlimitproviders = \"alpha\"\n")
    discard tryLoadStateOrEmpty(tmp)
    activeProviders = @[alpha, beta]
    check selectableProviders().mapIt(it.name) == @["alpha"]
    check activeProviders.mapIt(it.name) == @["alpha", "beta"]

  test "a current outside the whitelist falls back, not fails":
    writeConfig("[settings]\nlimitproviders = \"beta\"\n")
    discard tryLoadStateOrEmpty(tmp)
    activeProviders = @[alpha, beta]
    activeCurrent = "alpha.zai/glm-5.2"
    # Direct resolution over the narrowed pool misses (buildProfile is
    # the gate); the session resolver falls back to the first allowed
    # provider and aligns the sticky current with it.
    check buildProfile("alpha.zai/glm-5.2", selectableProviders(),
                       "").name == ""
    let prof = resolveSessionProfile("", "")
    check prof.name == "beta.zai/glm-5.2"
    check activeCurrent == "beta.zai/glm-5.2"

  test "an allowed current resolves unchanged":
    writeConfig("[settings]\nlimitproviders = \"alpha, beta\"\n")
    discard tryLoadStateOrEmpty(tmp)
    activeProviders = @[alpha, beta]
    activeCurrent = "beta.zai/glm-5.2"
    check resolveSessionProfile("", "").name == "beta.zai/glm-5.2"
    check activeCurrent == "beta.zai/glm-5.2"

  test "buildVerifierProfile refuses a non-allowed provider":
    writeConfig("[settings]\nlimitproviders = \"alpha\"\n")
    discard tryLoadStateOrEmpty(tmp)
    activeProviders = @[ProviderRec(name: "openrouter",
      url: "https://openrouter.ai/api/v1", key: "k",
      models: @["typesafe/jev-latest"])]
    let (prof, err) = buildVerifierProfile(
      "openrouter.typesafe/jev-latest", activeProviders)
    check prof.name == ""
    check err.contains("limitproviders")

  test "availableVerifiers skips non-allowed providers":
    writeConfig("[settings]\nlimitproviders = \"alpha\"\n")
    discard tryLoadStateOrEmpty(tmp)
    activeProviders = @[ProviderRec(name: "openrouter",
      url: "https://openrouter.ai/api/v1", key: "k",
      models: @["typesafe/jev-latest"])]
    check availableVerifiers(activeProviders).len == 0
    providerWhitelist = @[]
    check availableVerifiers(activeProviders).len == 1

  test "completion offers only allowed providers by name":
    writeConfig("[settings]\nlimitproviders = \"zai\"\n")
    discard tryLoadStateOrEmpty(tmp)
    let zai = ProviderRec(name: "zai", url: "https://z.ai", key: "k",
                          models: @["glm-5.2"])
    activeProviders = @[zai, beta]
    let names = completionFor(":provider ")
    check "zai" in names
    check "beta" notin names
    check "edit" in names  # management verbs stay offered
    # Management slots keep the full list: a limited directory can
    # still edit or remove a provider it cannot run.
    let editNames = completionFor(":provider edit ")
    check "beta" in editNames
    # Model specs complete only behind an allowed provider prefix
    # (glm-5.2 on zai is known-good, so the curation gate passes).
    check completionFor(":model beta.").len == 0
    check completionFor(":model zai.") == @["zai.glm-5.2"]
