# beck artifacts: per-FILE ask fix (sandwall 6548401) + bailout on Windows

Machine: beck (Win11 26100, fenced sandwall account). Suite binary built
from main; only the fence differs between the A/B runs.

- beck-ask-suite-FIXED-6548401-*.log - fixed fence: the goal's exact
  scenario passes: "a flips an exact file ask rule in place and the
  retry lands" [OK] = echo granted > vault/out.txt under allow ./ +
  ask ./vault/out.txt is DENIED, the ask card fires, granting 'a' flips
  the rule in place, the retry lands "granted", policy asserted.
  Remaining failures are the documented conhost render-split flake
  (roving, render-matching only; see ~/.agents/plan.md).
- beck-ask-suite-OLD-sandwall-5b9e0ea-*.log - pre-fix fence, same suite:
  the same leg FAILS at "allow write access to ./vault/out.txt?" never
  appearing - the write succeeded silently, no card (the shadowing).
- beck-provider-bailout-echo-FIXED-*.log - test_provider_bailout_echo
  on Windows: [OK], exit 0.
- beck-perfile-echo-fence-probe-*.log - headless fence probe: writes to
  ../ and to the ask-protected path both denied, reads ran, policy
  unchanged. (Headless loses the child's stdout/stderr capture - known
  relay quirk, separate issue.)
- sandwall-materialize-6548401.diff - the fence fix: materialize
  denied-but-missing targets so the DENY ACE bites, rolled back in
  endRun when pristine.
