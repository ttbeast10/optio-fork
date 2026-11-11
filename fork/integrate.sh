#!/usr/bin/env bash
# Rebuild the combined branch from scratch:
#
#   main + every branch in fork/branches.txt (in order) + fork/overlay
#
# The combined branch is generated, never edited: fix a bug on the topic
# branch it belongs to and run this again. The build happens in a throwaway
# worktree, so your checkout is not touched.
#
# Conflicts between two branches: the script stops and leaves the worktree
# for you. Resolve there, `git commit --no-edit`, then run it again with
# --continue. Resolutions are remembered (git rerere) and re-learned from the
# previous combined branch's merge commits, so each one is made once, also on
# another machine.
#
# Usage: [LEARN_FROM="<ref> ..."] fork/integrate.sh [--push] [--continue] [--no-fetch]
#   --push      push the result to the fork (force-with-lease; it is rebuilt each time)
#   --continue  carry on after you resolved a conflict in the worktree
#   LEARN_FROM  extra branches to learn conflict resolutions from (their merge commits)
set -euo pipefail
# shellcheck source=fork/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

push=0 cont=0 fetch=1
for a in "$@"; do
  case "$a" in
    --push) push=1 ;;
    --continue) cont=1 ;;
    --no-fetch) fetch=0 ;;
    *) die "unknown option $a" ;;
  esac
done

top="$(git rev-parse --show-toplevel)"
wt="${INTEGRATE_WORKTREE:-$top/../.optio-fork-combined}"
state="$(git rev-parse --git-common-dir)/optio-integrate-next"
g() { git -C "$wt" -c rerere.enabled=true -c rerere.autoupdate=true -c core.hooksPath=/dev/null "$@"; }

# Teach rerere the resolutions recorded in an earlier combined branch.
learn_from() {
  local old="$1" m p1 p2
  git rev-parse --verify --quiet "$old" >/dev/null || return 0
  for m in $(git rev-list --merges --reverse "$FORK_REMOTE/$MAIN..$old"); do
    p1="$(git rev-parse "$m^1")" p2="$(git rev-parse "$m^2")"
    g checkout --quiet --detach "$p1"
    if ! g merge --quiet --no-commit "$p2" >/dev/null 2>&1; then
      g rerere >/dev/null 2>&1 || true
      g checkout --quiet "$m" -- . 2>/dev/null || true
      g rerere >/dev/null 2>&1 || true
    fi
    g reset --quiet --hard
    g clean --quiet -fd
  done
}

merge_one() {
  local name="$1" ref="$2"
  if g merge-base --is-ancestor "$ref" HEAD; then
    echo "   $name: already included"
    return 0
  fi
  if g merge --quiet --no-ff --no-edit -m "chore(fork): merge $name into the combined branch" "$ref" >/dev/null 2>&1; then
    echo "   $name: merged"
    return 0
  fi
  # rerere replays (and stages) every resolution it has seen before.
  if [ -z "$(g diff --name-only --diff-filter=U)" ]; then
    g commit --quiet --no-edit
    echo "   $name: merged (conflicts resolved from memory)"
    return 0
  fi
  echo
  echo "CONFLICT merging $name. Unresolved files:"
  g diff --name-only --diff-filter=U | sed 's/^/   /'
  echo
  echo "Resolve them in $wt, then:"
  echo "   git -C $wt add -A && git -C $wt commit --no-edit"
  echo "   fork/integrate.sh --continue$([ "$push" = 1 ] && echo ' --push')"
  return 1
}

if [ "$cont" = 1 ]; then
  [ -d "$wt" ] && [ -f "$state" ] || die "nothing to continue"
  [ -z "$(g status --porcelain)" ] || die "the worktree still has uncommitted changes: commit the resolution first"
  mapfile -t todo <"$state"
else
  [ "$fetch" = 0 ] || fetch_all
  git worktree remove --force "$wt" 2>/dev/null || true
  git worktree add --quiet --detach "$wt" "$FORK_REMOTE/$MAIN"
  echo "Learning earlier conflict resolutions"
  learn_from "$FORK_REMOTE/$COMBINED"
  # Other branches whose merge commits hold resolutions worth reusing.
  for old in ${LEARN_FROM:-}; do learn_from "$old"; done
  g checkout --quiet --detach "$FORK_REMOTE/$MAIN"
  todo=()
  while read -r branch _; do todo+=("$branch"); done < <(read_branches)
  todo+=("$OVERLAY")
  echo "Building $COMBINED on $(g rev-parse --short HEAD) ($MAIN)"
fi

while [ "${#todo[@]}" -gt 0 ]; do
  b="${todo[0]}"
  todo=("${todo[@]:1}")
  printf '%s\n' "${todo[@]}" >"$state"
  g rev-parse --verify --quiet "$FORK_REMOTE/$b" >/dev/null || die "$b is not on $FORK_REMOTE"
  merge_one "$b" "$FORK_REMOTE/$b" || exit 1
done
rm -f "$state"

tip="$(g rev-parse HEAD)"
git branch --force "$COMBINED" "$tip" 2>/dev/null ||
  die "$COMBINED is checked out somewhere; the result is $tip in $wt"
echo "$COMBINED = $(git rev-parse --short "$tip")"
if [ "$push" = 1 ]; then
  git push --force-with-lease "$FORK_REMOTE" "$COMBINED"
fi
git worktree remove --force "$wt"
echo "Next: git checkout $COMBINED && deploy/airgap/bundle.sh <version> --tar   (deploy/airgap/README.md)"
