# Cybernetic plan: working sandwall sandbox on Windows

**DONE - see status.md.** The sandbox works end to end on Windows:
fs confinement, WFP fence, wall proxy enforcement, stdio relay, exit
codes, both session 0 and interactive session 1, through the real
bash-tool path. The blocker was three stacked bugs (desktop-shim heap
corruption, lpDesktop string, missing env passthrough) plus relay and
probe wiring - all dissected and fixed.

## Remaining (release steps)

1. [ ] Tag sandwall 0.5.0, push, watch CI. This release may be
   pushed (it is the deliverable).
2. [ ] 3code: bump the sandwall requirement to >= 0.5.0, update the
   README/manual-install section if it mentions the backend shape.
3. [ ] Optional hardening: ship sandwall.exe next to 3code.exe in the
   installer and exec it instead of re-execing 3code.
