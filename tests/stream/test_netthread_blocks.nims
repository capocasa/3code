## Test-only defines for the netthread lifetime suite.
##
## NetJoinBudgetMs shrinks the caller's worker-join/watchdog budget so the
## "late worker retired after budget expiry" test returns in ~2s instead
## of the production ~80s, while still leaving the stuck-provider test's
## worker (a 500ms recv wake after the interrupt) enough margin to join
## deterministically. NetReapWaitMs shrinks the worker's bounded wait for
## reap so a retired worker that publishes after its caller is gone exits
## promptly when no reaper comes. netWorkerTestHooks compiles in the
## worker gate (netWorkerGate) used to park a worker at the point modeling
## an uninterruptible resolver/connect; the gate and these budget
## overrides are inactive in production builds.
switch("define", "NetJoinBudgetMs=2000")
switch("define", "NetReapWaitMs=1500")
switch("define", "netWorkerTestHooks")
