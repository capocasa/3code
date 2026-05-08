Look at this output:

● bash   cat .agents/decisions.md 2>/dev/null || echo "(not found)"
  # Decisions

  A log of design decisions and their reasoning, so we don't relitigate
  … 93 lines hidden · :show 6 for full …
  ○6%  ↑3.1k  ↻4.7k  ↓42    5s

●
  ○6%      ↓17  0s

Especially the bottom part

●
  ○6%      ↓17  0s

(the top part is just a random tool call, for reference)

I believe this happens when the LLM starts outputting text (hence the text output bullet ●) but has not output anything yet. 
