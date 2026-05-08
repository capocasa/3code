# Impl 4: config.nim model resolution pipeline tests

**New file:** `tests/test_config_pipeline.nim`
**Module:** `threecode/config` (also uses `threecode/types` and `threecode/prompts` for `knownGoodFamily`, `isKnownGood`)
**Procs covered:** shortModel, shortToFull, findModel, resolveFamily, resolveReasoning, buildProfile, inferProvider, curatedFor, orderedModels, gateExperimental.

## Approach

Config's model-resolution pipeline is all pure logic — given a `ProviderRec` and/or a `Profile`, resolve the right family, reasoning level, and full model name. Construct `ProviderRec` and `Profile` objects directly in tests (no filesystem needed).

`inferProvider` and `curatedFor` are pure lookups against static catalogs.

## Imports

```nim
import std/[json, tables, unittest]
import threecode/[config, types]
# prompts needed implicitly for knownGoodFamily resolution inside resolveFamily
```

Note: `config.nim` already imports `prompts`, so `resolveFamily`/`buildProfile` call `knownGoodFamily` from prompts internally — no explicit import needed in the test.

## Test cases

### Suite: "config: shortModel"

1. **"strips everything before last slash"**
   ```nim
   check shortModel("openai/gpt-oss-120b") == "gpt-oss-120b"
   ```

2. **"returns full string when no slash"**
   ```nim
   check shortModel("gpt-oss-120b") == "gpt-oss-120b"
   ```

3. **"handles nested paths"**
   ```nim
   check shortModel("accounts/fireworks/models/glm-5p1") == "glm-5p1"
   ```

### Suite: "config: shortToFull"

4. **"maps short to full"**
   ```nim
   let t = shortToFull(@["openai/gpt-oss-120b", "meta/llama-4"])
   check t["gpt-oss-120b"] == "openai/gpt-oss-120b"
   check t["llama-4"] == "meta/llama-4"
   ```

5. **"first occurrence wins on collision"**
   ```nim
   let t = shortToFull(@["org/model", "model"])
   check t["model"] == "org/model"  # first one wins
   ```

6. **"empty input returns empty table"**
   ```nim
   let t = shortToFull(@[])
   check t.len == 0
   ```

### Suite: "config: findModel"

7. **"finds by full name"**
   ```nim
   let p = ProviderRec(name: "test", models: @["org/model-a", "org/model-b"])
   check p.findModel("org/model-a") == 0
   ```

8. **"finds by short name"**
   ```nim
   let p = ProviderRec(name: "test", models: @["org/model-a", "org/model-b"])
   check p.findModel("model-b") == 1
   ```

9. **"returns -1 when not found"**
   ```nim
   let p = ProviderRec(name: "test", models: @["org/model-a"])
   check p.findModel("nonexistent") == -1
   ```

### Suite: "config: inferProvider"

10. **"recognizes sk-ant- as anthropic"**
    ```nim
    check inferProvider("sk-ant-api03-xxx") == "anthropic"
    ```

11. **"recognizes sk-or- as openrouter"**
    ```nim
    check inferProvider("sk-or-v1-xxx") == "openrouter"
    ```

12. **"recognizes nvapi- as nvidia"**
    ```nim
    check inferProvider("nvapi-xxx") == "nvidia"
    ```

13. **"returns empty for unknown prefix"**
    ```nim
    check inferProvider("my-custom-key") == ""
    ```

### Suite: "config: curatedFor"

14. **"returns models for known provider"**
    ```nim
    let models = curatedFor("zai")
    check models.len > 0
    ```

15. **"returns empty for unknown provider"**
    ```nim
    check curatedFor("nonexistent").len == 0
    ```

### Suite: "config: resolveFamily"

16. **"known-good combo returns its family"**
    Construct a `ProviderRec` and `Profile` matching a known-good combo (e.g., provider "zai", model "glm-5.1"). Check `resolveFamily` returns "glm".

17. **"unknown model defaults to glm"**
    ```nim
    let prov = ProviderRec(name: "test", models: @["unknown-model"])
    let prof = Profile(name: "test.unknown-model", model: "unknown-model")
    check resolveFamily(prov, prof) == "glm"
    ```

### Suite: "config: resolveReasoning"

18. **"provider config reasoning wins"**
    ```nim
    let prov = ProviderRec(reasoning: "high")
    let prof = Profile(name: "test.model", model: "model")
    check resolveReasoning(prov, prof) == "high"
    ```

19. **"falls back to known-good default"**
    Construct a profile matching a known-good combo that has a default reasoning level. Check that level is returned.

20. **"returns empty when nothing set"**
    ```nim
    let prov = ProviderRec()
    let prof = Profile(name: "unknown.model", model: "model")
    check resolveReasoning(prov, prof) == ""
    ```

### Suite: "config: buildProfile"

21. **"builds profile for valid provider and model"**
    ```nim
    let prov = ProviderRec(name: "test", url: "https://api.test.com",
                           key: "sk-test", models: @["model-a"])
    let prof = buildProfile("test", @[prov], "test.model-a")
    check prof.name == "test.model-a"
    check prof.model == "model-a"
    check prof.url == "https://api.test.com"
    ```

22. **"returns empty profile for unknown provider"**
    ```nim
    let prof = buildProfile("", @[], "nonexistent.model")
    check prof.name == ""
    ```

23. **"picks first model when no model specified"**
    ```nim
    let prov = ProviderRec(name: "test", url: "https://api.test.com",
                           key: "sk-test", models: @["model-a", "model-b"])
    let prof = buildProfile("test", @[prov], "test")
    check prof.model == "model-a"
    ```

### Suite: "config: gateExperimental"

24. **"allows known-good profile"**
    ```nim
    let p = Profile(name: "zai.glm-5.1", family: "glm", model: "glm-5.1")
    check gateExperimental(p) == true
    ```
    Note: This test depends on "glm-5.1" being in `KnownGoodCombos` with provider "zai". Adjust the model name to match what's actually in the combos table (read `KnownGoodCombos` from `prompts.nim`).

25. **"blocks unknown profile when not experimental"**
    ```nim
    let p = Profile(name: "unknown.model", model: "model")
    check gateExperimental(p) == false
    ```

26. **"allows empty profile"**
    ```nim
    check gateExperimental(Profile()) == true
    ```

### Suite: "config: orderedModels"

27. **"known-good models come first"**
    ```nim
    let prov = ProviderRec(name: "zai", models: @["unknown", "glm-5.1"])
    let ordered = orderedModels(prov)
    # glm-5.1 should come before unknown since it's known-good
    check ordered.len == 2
    ```
    Note: Exact order depends on `KnownGoodCombos`. Verify by reading the combos table.

## Notes

- `ProviderRec` fields: `name`, `url`, `key`, `models` (seq[string]), `family`, `reasoning`, `reasonings` (seq[string]). Read the type definition in config.nim to confirm.
- `buildProfile` resolves family and reasoning internally via `resolveFamily`/`resolveReasoning`, which call `knownGoodFamily` from prompts.nim. Tests must use model/provider names that either are or aren't in the combos table.
- `experimentalEnabled` is a global bool in types.nim — it defaults to `false`. Do NOT set it in tests (would leak state). If needed, test with `experimentalEnabled = true` in a dedicated test and reset after.
- The `KnownGoodCombos` table in prompts.nim is the source of truth for which provider+model pairs are "known good". Read it to find valid test data.
