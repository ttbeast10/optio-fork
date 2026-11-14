#!/usr/bin/env bash
# Rebase every topic branch in branches.txt onto upstream's current main (a
# stacked branch onto its parent's new tip), each in its own worktree at
# ../rb-<branch with / as ->. A conflict only in CHANGELOG.md's [Unreleased]
# section is resolved by fork/resolve-changelog.mjs; any other conflict stops
# that branch's rebase where it is, for a person or an agent to resolve.
#
# Nothing is pushed: run `pnpm check:push` in each worktree, then
# `git push --force-with-lease origin <branch>`.
#
# One line per branch on stdout:
#   <branch> UP-TO-DATE | REBASED <sha> | MERGED | CONFLICT <worktree> <files…>
#
# Usage: fork/rebase.sh [<branch>…]   (default: every branch in branches.txt)
set -uo pipefail
# shellcheck source=fork/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fetch_all
main="$UPSTREAM_REMOTE/$MAIN"
root="$(git rev-parse --show-toplevel)"
resolver="$FORK_DIR/resolve-changelog.mjs"
declare -A new_tip

in_rebase() {
  local gd
  gd="$(git rev-parse --git-dir)"
  [ -d "$gd/rebase-merge" ] || [ -d "$gd/rebase-apply" ]
}

while read -r branch parent; do
  [ "$#" -eq 0 ] || printf '%s\n' "$@" | grep -qx "$branch" || continue
  ref="$FORK_REMOTE/$branch"
  if ! git rev-parse --verify --quiet "$ref" >/dev/null; then
    echo "$branch MISSING"
    continue
  fi
  if [ "$parent" = "-" ]; then
    onto="$main"
    from="$(git merge-base "$ref" "$main")"
  else
    onto="${new_tip[$parent]:-$FORK_REMOTE/$parent}"
    from="$(git merge-base "$ref" "$FORK_REMOTE/$parent")"
  fi
  if [ "$parent" = "-" ] && [ -z "$(git cherry "$main" "$ref" | grep '^+')" ]; then
    echo "$branch MERGED"
    continue
  fi
  if [ "$(git rev-parse "$from")" = "$(git rev-parse "$onto")" ]; then
    new_tip[$branch]="$ref"
    echo "$branch UP-TO-DATE"
    continue
  fi
  wt="$(dirname "$root")/rb-${branch//\//-}"
  git worktree remove --force "$wt" >/dev/null 2>&1
  git worktree add --quiet -B "$branch" "$wt" "$ref" || { echo "$branch WORKTREE-FAILED"; continue; }
  (
    cd "$wt" || exit 9
    git branch --quiet --set-upstream-to="$main" >/dev/null 2>&1
    git rebase --quiet --onto "$onto" "$from" >/dev/null 2>&1
    while in_rebase; do
      files="$(git diff --name-only --diff-filter=U)"
      if [ -z "$files" ]; then
        GIT_EDITOR=true git rebase --continue >/dev/null 2>&1 || GIT_EDITOR=true git rebase --skip >/dev/null 2>&1
      elif [ "$files" = "CHANGELOG.md" ] && node "$resolver" CHANGELOG.md >/dev/null 2>&1; then
        GIT_EDITOR=true git rebase --continue >/dev/null 2>&1
      else
        echo "$branch CONFLICT $wt $(echo "$files" | tr '\n' ' ')"
        exit 1
      fi
    done
    if [ "$(git rev-parse HEAD)" = "$(git rev-parse "$onto")" ]; then
      echo "$branch MERGED (every commit is already in $onto)"
    else
      echo "$branch REBASED $(git rev-parse --short HEAD)"
    fi
  ) && new_tip[$branch]="$(git -C "$wt" rev-parse HEAD)"
done < <(read_branches)
