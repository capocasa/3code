#!/bin/sh
# Install the contract-tier pre-commit hook (opt-in).
#
# The hook runs `nimble testContract` (2-3 min) only when a commit touches
# src/, so documentation and test-only commits stay instant. Installing it
# is opt-in because it makes every source commit pay that time.
set -eu
hook=$(git rev-parse --git-path hooks)/pre-commit
mkdir -p "$(dirname "$hook")"
{
  echo '#!/bin/sh'
  echo '# Installed by tests/tools/install_hooks.sh.'
  echo 'if git diff --cached --quiet -- src/; then'
  echo '  exit 0'
  echo 'fi'
  echo 'echo "pre-commit: running the interactive contract tier (nimble testContract)"'
  echo 'nimble testContract || {'
  echo '  echo "pre-commit: contract tier failed; commit blocked" >&2'
  echo '  exit 1'
  echo '}'
} > "$hook"
chmod +x "$hook"
echo "installed $hook"
