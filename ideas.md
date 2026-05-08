# Auto-read

Before each callModel, scan the latest user message for lines that are bare file paths (exist on disk), read them, and inject the contents as tool-result blocks. The model arrives with files already in context.

## Pros
- Eliminates the first-turn "read the file" churn on every prompt
- Works for user messages, context_clear instructions, system prompt
- Same shape as normal read results — no new concepts for the model
- Files referenced in tasks are almost always needed anyway

## Cons
- Cannot distinguish "read this now" from "this file might be relevant" — user intent is semantic
- System prompt references (skills, config) should NOT be pre-loaded — the agent reads them on demand
- False positives: bare filenames that happen to exist (LICENSE, binary names)
- Adds implementation complexity to the hot path (every callModel)
- Line-level "bare path" heuristic requires the prompt author to learn a convention — uneconomical in brain cycles

## Status
Shelved. The core problem (saving turns on file reads) is real but the mechanism keeps getting overengineered. Revisit if a simpler framing emerges.

---

# Amnesia: filename vs string disambiguation

The `next_file` parameter on the amnesia tool should accept either a filename (verified to exist, error if not) or a freeform string (passed through as instructions). Need a way to distinguish them without ambiguity.

Options:
- Require filenames to not contain spaces (fragile, paths can have spaces)
- Require filenames to have a known extension (.md, .nim, etc.) — duck-type by extension
- A separate parameter: `next_file` for filenames, `instructions` for strings
- A prefix marker like `@` for filenames (but we rejected special syntax)

Low priority. The chunked-implementation use case only needs filenames. General string support can wait until a real use case surfaces.
