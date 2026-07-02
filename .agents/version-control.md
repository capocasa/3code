# Version control policy

## Commit messages

All commit messages are short, sweet, to-the-point one-liners. No body,
no co-author trailer, no ceremony.

## Branches and worktrees

Feature work happens on branches. The `main` branch is the integration
target and must always be buildable and testable.

Multiple worktrees may be active at once. Git serializes index and ref
updates, so concurrent worktrees on different branches are safe and do
not require coordination beyond the normal pull/merge cycle.

## History rewrites

History rewrites (`git rebase` that rewrites published history, `git
filter-branch`, `git filter-repo`, `git commit --amend` on shared commits,
and force-pushes that change commit SHAs) are forbidden while feature
branches are checked out in another worktree.

