#!/usr/bin/env bash
# Bring the fork's main level with upstream's (a fast-forward, nothing else),
# then report every topic branch against it.
#
# Usage: fork/sync.sh
set -euo pipefail
# shellcheck source=fork/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fetch_all
up="$(git rev-parse "$UPSTREAM_REMOTE/$MAIN")"
mine="$(git rev-parse "$FORK_REMOTE/$MAIN")"
if [ "$up" = "$mine" ]; then
  echo "main is level with upstream ($(git rev-parse --short "$up"))"
elif git merge-base --is-ancestor "$mine" "$up"; then
  n="$(git rev-list --count "$mine..$up")"
  echo "upstream is $n commit(s) ahead; fast-forwarding $FORK_REMOTE/$MAIN"
  git push "$FORK_REMOTE" "$up:refs/heads/$MAIN"
  git fetch --quiet "$FORK_REMOTE" "$MAIN"
else
  die "$FORK_REMOTE/$MAIN has commits upstream does not: main must only mirror upstream. Fix that by hand."
fi
echo
exec "$FORK_DIR/status.sh" --no-fetch
