## Deterministic late-worker lifecycle tests: the compile-time worker
## barrier (-d:netWorkerTestBarrier) parks the worker before any fd
## exists, standing in for an uninterruptible resolver/connect wedge, and
## the caller's join budget (-d:NetJoinBudgetMs) shrinks so retirement
## happens on test timescales. Both seams are inactive in production.
switch("define", "netWorkerTestBarrier")
switch("define", "NetJoinBudgetMs=1500")
