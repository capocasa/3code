## Test-only define for the aside suite.
##
## BtwReapWaitMs shrinks the retired worker's wait for a reap handshake
## that a cancelled aside never gets. The worker polls it in 1ms sleeps,
## so its real duration is the host's sleep granularity times the budget:
## ~5s on Linux, well past that on macOS. The interrupt test waits
## BtwReapWaitMs div 1000 + 4 whole seconds for the worker to report
## gone, a budget that only holds when each iteration really is 1ms.
switch("define", "BtwReapWaitMs=1000")
