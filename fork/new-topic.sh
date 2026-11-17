#!/usr/bin/env bash
# Start a change: a new topic branch from the fork's main (= upstream's main)
# in a worktree of its own, with the fork's agent notes beside it.
#
# Usage: fork/new-topic.sh <type>/<name> [<parent-branch>]
#   fork/new-topic.sh fix/login-redirect
#   fork/new-topic.sh feat/part-2 feat/part-1      # stacked on another topic branch
set -euo pipefail
# shellcheck source=fork/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

branch="${1:-}"
parent="${2:-}"
[[ "$branch" =~ ^(feat|fix|refactor|perf|docs|test|chore|build|ci)/[a-z0-9][a-z0-9._-]*$ ]] ||
  die "usage: fork/new-topic.sh <type>/<name>   (e.g. fix/login-redirect)"

fetch_all
git rev-parse --verify --quiet "refs/remotes/$FORK_REMOTE/$branch" >/dev/null &&
  die "$branch already exists on $FORK_REMOTE"
base="$FORK_REMOTE/$MAIN"
if [ -n "$parent" ]; then
  base="$FORK_REMOTE/$parent"
  git rev-parse --verify --quiet "$base" >/dev/null || die "$parent is not on $FORK_REMOTE"
elif [ "$(git rev-parse "$FORK_REMOTE/$MAIN")" != "$(git rev-parse "$UPSTREAM_REMOTE/$MAIN")" ]; then
  die "$FORK_REMOTE/$MAIN is not level with upstream: run fork/sync.sh first"
fi

top="$(git rev-parse --show-toplevel)"
dir="$(dirname "$top")/optio-${branch//\//-}"
[ ! -e "$dir" ] || die "$dir already exists"
git worktree add --quiet -b "$branch" "$dir" "$base"
git -C "$dir" config "branch.$branch.remote" "$FORK_REMOTE"
git -C "$dir" config "branch.$branch.merge" "refs/heads/$branch"

# The fork's notes for agents, where Claude Code reads them, kept out of git:
# a topic branch must not carry fork-only files.
exclude="$(git rev-parse --path-format=absolute --git-common-dir)/info/exclude"
grep -qxF 'CLAUDE.local.md' "$exclude" 2>/dev/null || echo 'CLAUDE.local.md' >>"$exclude"
{
  echo "<!-- Copied from fork/CLAUDE.md (branch fork/overlay) by fork/new-topic.sh. Not tracked. -->"
  echo
  cat "$FORK_DIR/CLAUDE.md"
} >"$dir/CLAUDE.local.md"

echo "$branch, from $base, in $dir"
echo "Next: cd $dir && pnpm install"
if [ -n "$parent" ]; then
  echo "When it joins the combined build, its line in fork/branches.txt is: $branch after $parent"
fi
