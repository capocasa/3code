# Impl 7: prompts.nim + compact.nim pure-logic tests

**New file:** `tests/test_prompts_compact.nim`
**Modules:** `threecode/prompts`, `threecode/compact`
**Procs covered:** knownGoodFamily (both overloads), isKnownGood, knownGoodTags, knownGoodReasoning, reasoningSupported, defaultReasoningsFor, buildCredit, contextWindowFor, decideContextAction.

## Approach

All pure lookup/logic functions. `prompts.nim` procs query the `KnownGoodCombos` table. `compact.nim` procs are heuristics for context window sizing and action decisions. No side effects — construct `Profile` objects and call.

## Imports

```nim
import std/[json, unittest]
import threecode/[prompts, compact, types]
```

## Test cases

### Suite: "prompts: knownGoodFamily"

Read `KnownGoodCombos` from prompts.nim to find valid test data. The combos are tuples of `(provider, model, family, version, variant, reasoning, temperature, maxTokens, xmlFallback)`.

1. **"returns family for known-good combo"**
    ```nim
    # Use actual known-good combos from the source
    check knownGoodFamily("zai", "glm-5.1") == "glm"
    ```
    Note: Adjust provider/model to match what's actually in `KnownGoodCombos`.

2. **"returns empty for unknown combo"**
    ```nim
    check knownGoodFamily("unknown", "model") == ""
    ```

3. **"Profile overload returns family"**
    ```nim
    let p = Profile(name: "zai.glm-5.1", model: "glm-5.1")
    check knownGoodFamily(p) == "glm"
    ```

4. **"Profile overload returns empty for empty profile"**
    ```nim
    check knownGoodFamily(Profile()) == ""
    ```

5. **"case-insensitive match"**
    ```nim
    check knownGoodFamily("ZAI", "GLM-5.1") == "glm"
    ```

### Suite: "prompts: isKnownGood"

6. **"true for known-good profile"**
    ```nim
    let p = Profile(name: "zai.glm-5.1", model: "glm-5.1")
    check isKnownGood(p)
    ```

7. **"false for unknown profile"**
    ```nim
    let p = Profile(name: "unknown.model", model: "model")
    check not isKnownGood(p)
    ```

8. **"false for empty profile"**
    ```nim
    check not isKnownGood(Profile())
    ```

### Suite: "prompts: knownGoodTags"

9. **"returns tags for known-good combo"**
    ```nim
    let (family, ver, vrt) = knownGoodTags("zai", "glm-5.1")
    check family == "glm"
    check ver.len > 0 or vrt.len > 0  # at least one tag should be set
    ```

10. **"returns empty strings for unknown"**
    ```nim
    let (f, v, r) = knownGoodTags("unknown", "model")
    check f == ""
    check v == ""
    check r == ""
    ```

### Suite: "prompts: knownGoodReasoning"

11. **"returns reasoning level for known-good combo"**
    ```nim
    let r = knownGoodReasoning("zai", "glm-5.1")
    check r in ["", "low", "medium", "high"]
    ```

12. **"returns empty for unknown"**
    ```nim
    check knownGoodReasoning("unknown", "model") == ""
    ```

### Suite: "prompts: reasoningSupported"

13. **"true for gpt-oss"**
    ```nim
    check reasoningSupported("gpt-oss")
    ```

14. **"true for glm"**
    ```nim
    check reasoningSupported("glm")
    ```

15. **"true for deepseek"**
    ```nim
    check reasoningSupported("deepseek")
    ```

16. **"true for minimax"**
    ```nim
    check reasoningSupported("minimax")
    ```

17. **"false for unknown family"**
    ```nim
    check not reasoningSupported("llama")
    ```

### Suite: "prompts: defaultReasoningsFor"

18. **"returns levels for supported family"**
    ```nim
    let levels = defaultReasoningsFor("glm")
    check levels == @["low", "medium", "high"]
    ```

19. **"returns empty for unsupported family"**
    ```nim
    check defaultReasoningsFor("llama").len == 0
    ```

### Suite: "prompts: buildCredit"

20. **"builds attribution for valid profile"**
    ```nim
    let p = Profile(name: "zai.glm-5.1", model: "glm-5.1")
    let credit = buildCredit(p)
    check "glm-5.1" in credit
    check "zai" in credit
    ```

21. **"uses fallback for empty profile"**
    ```nim
    let credit = buildCredit(Profile())
    check "Credit" in credit
    check credit.contains("whoever trained")
    ```

### Suite: "compact: contextWindowFor"

22. **"glm returns 128000"**
    ```nim
    check contextWindowFor("glm-5.1") == 128_000
    ```

23. **"claude returns 200000"**
    ```nim
    check contextWindowFor("claude-3.5-sonnet") == 200_000
    ```

24. **"deepseek returns 128000"**
    ```nim
    check contextWindowFor("deepseek-v3") == 128_000
    ```

25. **"gemini returns 1000000"**
    ```nim
    check contextWindowFor("gemini-2.0-pro") == 1_000_000
    ```

26. **"gpt-5 returns 400000"**
    ```nim
    check contextWindowFor("gpt-5") == 400_000
    ```

27. **"gpt-4 returns 128000"**
    ```nim
    check contextWindowFor("gpt-4o") == 128_000
    ```

28. **"qwen returns 128000"**
    ```nim
    check contextWindowFor("qwen-2.5") == 128_000
    ```

29. **"llama returns 128000"**
    ```nim
    check contextWindowFor("llama-3.1") == 128_000
    ```

30. **"unknown returns 128000 (default)"**
    ```nim
    check contextWindowFor("unknown-model") == 128_000
    ```

31. **"qwen3-coder returns 262144"**
    ```nim
    check contextWindowFor("qwen3-coder-480b") == 262_144
    ```

32. **"case insensitive"**
    ```nim
    check contextWindowFor("GLM-5.1") == 128_000
    ```

33. **"o1/o3/o4 models return 200000"**
    ```nim
    check contextWindowFor("o1-preview") == 200_000
    check contextWindowFor("o3-mini") == 200_000
    ```

34. **"kimi-k2 returns 128000"**
    ```nim
    check contextWindowFor("kimi-k2") == 128_000
    ```

### Suite: "compact: decideContextAction"

35. **"returns caNone when under threshold"**
    ```nim
    check decideContextAction(1000, 128_000, 10) == caNone
    ```

36. **"returns caSummarize when over threshold and enough messages"**
    ```nim
    # Default threshold is 0.8, so 100k/128k = 0.78 → under.
    # 110k/128k = 0.859 → over. Default keepRecent = 10, so need 14+ messages.
    check decideContextAction(110_000, 128_000, 20) == caSummarize
    ```

37. **"returns caCompact when over threshold but too few messages"**
    ```nim
    # Over threshold but fewer than keepRecent + 4 messages
    check decideContextAction(110_000, 128_000, 5) == caCompact
    ```

38. **"returns caNone for zero tokens"**
    ```nim
    check decideContextAction(0, 128_000, 20) == caNone
    ```

39. **"returns caNone for zero window"**
    ```nim
    check decideContextAction(100_000, 0, 20) == caNone
    ```

40. **"custom threshold"**
    ```nim
    # threshold 0.5, so 70k/128k = 0.547 → over
    check decideContextAction(70_000, 128_000, 20, threshold = 0.5) == caSummarize
    ```

## Notes

- Read `KnownGoodCombos` in prompts.nim before writing tests — the exact provider/model strings determine which tests pass. The table is a `const` array of tuples.
- `contextWindowFor` uses substring matching — test with model names that could cause false positives (e.g., a hypothetical model named "o1o" shouldn't match the o1 branch unless "o1" is a substring, which it is). These are known limitations of the heuristic approach.
- `decideContextAction` has defaults `keepRecent = SummarizeKeepRecent` and `threshold = SummarizeThresholdFrac` — read the constants from compact.nim source.
- `buildCredit` returns a string with specific format — check for key substrings rather than exact match to avoid fragility when the template changes.
