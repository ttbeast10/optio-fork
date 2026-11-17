#!/usr/bin/env bash
# Shared by the fork/ scripts: where things are and how to read branches.txt.
# shellcheck shell=bash

FORK_REMOTE="${FORK_REMOTE:-origin}"
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/jonwiggins/optio}"
UPSTREAM_REPO="${UPSTREAM_REPO:-jonwiggins/optio}"
FORK_OWNER="${FORK_OWNER:-ttbeast10}"
MAIN="${MAIN:-main}"
COMBINED="${COMBINED:-fork/combined}"
OVERLAY="${OVERLAY:-fork/overlay}"
# Paths that exist only in the fork. A topic branch must not touch them.
# shellcheck disable=SC2034  # read by the scripts that source this file
FORK_ONLY_PATHS=(fork deploy/airgap)

FORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRANCH_LIST="${BRANCH_LIST:-$FORK_DIR/branches.txt}"

die() {
  echo "error: $*" >&2
  exit 1
}

# Prints "<branch> <parent-or-->" for every line of branches.txt.
read_branches() {
  local line branch kw parent
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    read -r branch kw parent <<<"$line" || true
    [ -n "$branch" ] || continue
    if [ "$kw" = "after" ] && [ -n "$parent" ]; then
      echo "$branch $parent"
    else
      echo "$branch -"
    fi
  done <"$BRANCH_LIST"
}

fetch_all() {
  git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1 ||
    git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
  git fetch --quiet "$UPSTREAM_REMOTE" "$MAIN"
  git fetch --quiet --prune "$FORK_REMOTE" "+refs/heads/*:refs/remotes/$FORK_REMOTE/*"
}
