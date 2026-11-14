#!/usr/bin/env bash
# One line per topic branch: is it a clean pull request for upstream?
#
#   base     ok        based on the current main (or on its stack parent)
#            behind N  N commits of main it does not have: rebase it
#   alone    ok        merges into main by itself without conflicts
#            CONFLICT  it no longer applies to main: rebase and resolve
#   pr       clean     touches nothing fork-only, adds no large file
#            DIRTY     see the notes under the table
#   state    N ahead   commits the pull request would carry
#            merged    nothing left that main lacks: drop it from branches.txt
#
# Usage: fork/status.sh [--no-fetch]
# Exits 1 when a branch needs attention.
set -euo pipefail
# shellcheck source=fork/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ "${1:-}" = "--no-fetch" ] || fetch_all
main="$FORK_REMOTE/$MAIN"
bad=0
notes=()

printf '%-42s %-11s %-9s %-6s %s\n' BRANCH BASE ALONE PR STATE
while read -r branch parent; do
  ref="$FORK_REMOTE/$branch"
  if ! git rev-parse --verify --quiet "$ref" >/dev/null; then
    printf '%-42s %s\n' "$branch" "MISSING on $FORK_REMOTE"
    bad=1
    continue
  fi
  base_ref="$main"
  [ "$parent" = "-" ] || base_ref="$FORK_REMOTE/$parent"

  behind="$(git rev-list --count "$ref..$base_ref")"
  base="ok"
  if [ "$behind" != 0 ]; then
    base="behind $behind"
    bad=1
  fi

  alone="ok"
  if ! git merge-tree --write-tree "$main" "$ref" >/dev/null 2>&1; then
    alone="CONFLICT"
    bad=1
  fi

  pr="clean"
  touched="$(git diff --name-only "$base_ref...$ref" -- "${FORK_ONLY_PATHS[@]}")"
  if [ -n "$touched" ]; then
    pr="DIRTY"
    bad=1
    notes+=("$branch touches fork-only files: $(echo "$touched" | tr '\n' ' ')")
  fi
  archives="$(git diff --name-only --diff-filter=A "$base_ref...$ref" | grep -E '\.(tar(\.[a-z0-9]+)?|tgz|zip|jar)$' || true)"
  if [ -n "$archives" ]; then
    pr="DIRTY"
    bad=1
    notes+=("$branch adds an archive: $(echo "$archives" | tr '\n' ' ')")
  fi
  while read -r _ _ _ size path; do
    [ -n "$path" ] || continue
    if [ "$size" != "-" ] && [ "$size" -gt 1000000 ]; then
      pr="DIRTY"
      bad=1
      notes+=("$branch adds a large file: $path ($((size / 1024)) KiB)")
    fi
  done < <(git diff --name-only --diff-filter=A "$base_ref...$ref" |
    while IFS= read -r p; do git ls-tree -l "$ref" -- "$p"; done)

  # Merged upstream (squashed or not) = merging it into main changes nothing.
  ahead="$(git rev-list --count "$base_ref..$ref")"
  state="$ahead ahead"
  merged_tree="$(git merge-tree --write-tree "$main" "$ref" 2>/dev/null | head -1 || true)"
  if [ "$merged_tree" = "$(git rev-parse "$main^{tree}")" ]; then
    state="merged upstream"
  fi
  [ "$parent" = "-" ] || state="$state, after $parent"

  printf '%-42s %-11s %-9s %-6s %s\n' "$branch" "$base" "$alone" "$pr" "$state"
done < <(read_branches)

if [ "${#notes[@]}" -gt 0 ]; then
  echo
  printf 'note: %s\n' "${notes[@]}"
fi
exit "$bad"
