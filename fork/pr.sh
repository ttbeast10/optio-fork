#!/usr/bin/env bash
# Open (or print the link that opens) a pull request to upstream for one topic
# branch. Refuses a branch that is not a clean pull request.
#
# Usage: fork/pr.sh <branch>
set -euo pipefail
# shellcheck source=fork/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

branch="${1:-}"
[ -n "$branch" ] || die "usage: fork/pr.sh <branch>"
fetch_all
ref="$FORK_REMOTE/$branch"
git rev-parse --verify --quiet "$ref" >/dev/null || die "$branch is not on $FORK_REMOTE: push it first"
main="$UPSTREAM_REMOTE/$MAIN"

behind="$(git rev-list --count "$ref..$main")"
[ "$behind" = 0 ] || die "$branch is $behind commit(s) behind upstream main: rebase it first (a stacked branch waits for its parent to merge)"
touched="$(git diff --name-only "$main...$ref" -- "${FORK_ONLY_PATHS[@]}")"
[ -z "$touched" ] || die "$branch touches fork-only files: $touched"

title="$(git log -1 --format=%s "$(git rev-list --reverse "$main..$ref" | head -1)")"
echo "$branch: $(git rev-list --count "$main..$ref") commit(s), $(git diff --shortstat "$main...$ref")"
if command -v gh >/dev/null 2>&1; then
  exec gh pr create --repo "$UPSTREAM_REPO" --base "$MAIN" --head "$FORK_OWNER:$branch" --title "$title" --web
fi
echo "Open: https://github.com/$UPSTREAM_REPO/compare/$MAIN...$FORK_OWNER:$branch?expand=1"
