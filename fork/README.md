# How this fork works

`ttbeast10/optio-fork` is a fork of [`jonwiggins/optio`](https://github.com/jonwiggins/optio)
(**upstream**). It exists for two things:

1. **Sending clean pull requests to upstream.** One change per pull request,
   nothing fork-specific in it.
2. **Running several of those changes together** as one air-gap build,
   before (and while) they wait to be merged upstream.

Those two pull in opposite directions, so the branches are kept strictly
apart. This page is the map. Agents get the short version from
`fork/CLAUDE.md`.

## The branches

```
upstream main  (jonwiggins/optio)
      │  fork/sync.sh: fast-forward only
      ▼
    main ──────┬───────────────┬───────────────┬────────────────┐
               │               │               │                │
        fix/one-thing    feat/another    feat/part-1      fork/overlay
               │               │               │           (fork/ + deploy/airgap/)
               │               │         feat/part-2            │
               ▼               ▼               ▼                ▼
    fork/combined  =  main + every topic branch + fixups + fork/overlay
               │
               └─► images, air-gap bundle, the k3s preview
```

| Branch            | What it is                                                                                             | Who changes it                               |
| ----------------- | ------------------------------------------------------------------------------------------------------ | -------------------------------------------- |
| `main`            | **A copy of upstream's `main`, nothing else.** It has no commits of its own and is never worked on.    | `fork/sync.sh` only (a fast-forward)         |
| `feat/…`, `fix/…` | A **topic branch**: one change, started from `main`. It becomes one upstream pull request.             | you                                          |
| `fork/overlay`    | **The fork's own files**: `fork/` (these docs and tools) and `deploy/airgap/` (bundle, deploy, check). | you                                          |
| `fork/combined`   | **The fork's "main"**: `main` + every branch in `fork/branches.txt` + `fork/overlay`. What gets built. | `fork/integrate.sh` only (rebuilt each time) |
| `backup/<date>/…` | Snapshots taken before a branch was rewritten.                                                         | nobody; delete when no longer needed         |

So there are two things people call "main":

- **`main`** answers "what does upstream have?" Start every change from it.
- **`fork/combined`** answers "what do we run?" Build and deploy from it,
  never commit to it.

Leftovers from before this layout (`airgap/main`,
`claude/gitlab-hosts-pod-per-session-somjrh`, `ccr-…`, `feat/jira-data-center`)
are superseded and can be deleted.

## The five rules

1. **Work on a topic branch, started from `main`.** Never commit to `main`
   or to `fork/combined`.
2. **A topic branch touches nothing under `fork/` or `deploy/airgap/`**, and
   those change only on `fork/overlay`. That is what keeps pull requests clean.
3. **A bug found in the combined build is fixed where it belongs**: on the
   topic branch that owns the code, then `fork/integrate.sh --push`.
4. **One branch, one pull request.** A big change split into parts is a
   stack (below), not one branch with everything.
5. **Rewritten branches are pushed with `--force-with-lease`**, never
   `--force`. Nothing is ever pushed to upstream.

## Set up a clone

```bash
git clone https://github.com/ttbeast10/optio-fork && cd optio-fork
git remote add upstream https://github.com/jonwiggins/optio
git worktree add ../optio-fork-tools origin/fork/overlay     # the tools live here
```

Run every `fork/…` command from `../optio-fork-tools` (a checkout of
`fork/overlay`). `gh` must be signed in to open pull requests.

## Develop a change

```bash
cd ../optio-fork-tools
fork/sync.sh                               # main level with upstream; a report on every branch
fork/new-topic.sh feat/my-change           # a worktree at ../optio-feat-my-change, from main
cd ../optio-feat-my-change && pnpm install
# … work, commit (conventional commits) …
pnpm check:push && git push -u origin feat/my-change
```

`AGENTS.md` describes the code, the test tiers and the hooks; all of it
applies. Then try it together with everything else:

```bash
cd ../optio-fork-tools
# add the line "feat/my-change" to fork/branches.txt, commit, push
fork/integrate.sh --push                   # rebuilds fork/combined
```

and check the combined code (below) before building anything from it.

## Open the pull request on upstream

```bash
# write fork/pr/feat-my-change.md: line 1 the title, a blank line, then the
# description under upstream's headings (Summary, Changes, Testing, Related)
fork/pr.sh feat/my-change
```

`pr.sh` refuses a branch that is behind upstream's `main` or touches
fork-only files, then opens the pull request on `jonwiggins/optio` from
`ttbeast10:feat/my-change`. Without a description file it opens the browser
form instead. Say in the description what was and was not run locally;
tick the `pnpm check:push` box only if it passed.

After it is open: upstream squash-merges. Answer review by adding commits
to the topic branch and pushing; rebuild `fork/combined` when the change
matters to the deployment.

## A big change in small pull requests (a stack)

Part 2 is started from part 1, not from `main`, and `branches.txt` says so:

```
feat/part-1
feat/part-2 after feat/part-1
```

Upstream takes a stack one at a time, because a pull request from a fork
can only target upstream's `main`: open part 1; when it is merged, move
part 2 onto the new `main` and open it:

```bash
fork/sync.sh
git rebase --onto upstream/main <old tip of feat/part-1> feat/part-2
git push --force-with-lease origin feat/part-2      # then remove part-1 from branches.txt
fork/pr.sh feat/part-2
```

Changes that do not depend on each other are separate topic branches and
can all be open at once.

## When things move

| What happened                            | What to do                                                                                                                                             |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Upstream has new commits                 | `fork/sync.sh`. Rebase each branch it reports `behind` (`git rebase upstream/main`, `pnpm check:push`, `git push --force-with-lease`), then integrate. |
| A pull request was merged upstream       | `fork/sync.sh` shows it `merged upstream`. Remove its line from `branches.txt`, delete the branch, integrate. The change now comes from `main`.        |
| `integrate.sh` stops on a conflict       | Two branches edit the same lines. Resolve in the worktree it names, commit, `fork/integrate.sh --continue`. It is remembered: you resolve it once.     |
| The combined code does not build or pass | One branch's own bug: fix it on that branch. Two branches breaking each other without a conflict: a fixup (next section).                              |
| A branch shows `DIRTY`                   | It touches `fork/` or `deploy/airgap/`, or adds an archive / large file. Take that out of the branch.                                                  |

## Fixups: branches that merge cleanly but break each other

One branch renames a function another calls: `git` merges them without a
conflict and the result does not compile. The repair is a patch in
`fork/fixups/<nn>-<name>.patch` (a `git diff` made on `fork/combined`, with
a few lines on top saying which branches it is for). `integrate.sh` applies
every patch after the topic branches.

A fixup is a debt to upstream: **whichever of the two pull requests is
merged second must carry that change itself.** When the first is merged,
rebase the other, apply the patch to it, and delete the patch file.

## Check, build and deploy the combined branch

```bash
git worktree add ../optio-fork-combined origin/fork/combined    # the first time
cd ../optio-fork-combined
git fetch && git reset --hard origin/fork/combined    # later: it is rebuilt each time, so reset to it, don't pull
pnpm install && pnpm check:push --full                # every suite, browser tests included

deploy/airgap/bundle.sh 0.25.0-fork.N --tar           # → release/optio-airgap-0.25.0-fork.N/
```

Deploying the bundle to a cluster and checking it is in
`deploy/airgap/README.md`. Version bundles `<upstream version>-fork.<n>`.

## Commands

| Command                      | Does                                                                             |
| ---------------------------- | -------------------------------------------------------------------------------- |
| `fork/sync.sh`               | Fast-forwards `main` to upstream, then prints the status report.                 |
| `fork/status.sh`             | Per branch: based on `main`? applies alone? clean pull request? merged upstream? |
| `fork/new-topic.sh <branch>` | A new topic branch from `main` in its own worktree, with the fork's agent notes. |
| `fork/integrate.sh [--push]` | Rebuilds `fork/combined` from `branches.txt`, the fixups and `fork/overlay`.     |
| `fork/pr.sh <branch>`        | Opens the upstream pull request, with `fork/pr/<branch>.md` as its description.  |

`status.sh` columns: `BASE` (`behind N` = rebase it), `ALONE` (`CONFLICT` =
it no longer applies to `main` by itself), `PR` (`DIRTY` = not a clean pull
request), `STATE` (`N ahead`, or `merged upstream` = drop it from the list).

## What is where

| Path                    | What                                                                        |
| ----------------------- | --------------------------------------------------------------------------- |
| `fork/README.md`        | This page.                                                                  |
| `fork/CLAUDE.md`        | The same rules, short, for coding agents. Imported by the root `CLAUDE.md`. |
| `fork/branches.txt`     | The topic branches in the combined build, in merge order.                   |
| `fork/pr/<branch>.md`   | Each pull request's title and description.                                  |
| `fork/fixups/*.patch`   | Repairs for branches that break each other.                                 |
| `fork/LOCAL-SESSION.md` | The runbook used for the first tidy-up, bundle and k3s rehearsal (2026-11). |
| `deploy/airgap/`        | Bundle, deploy and check an air-gapped install.                             |

## Open upstream pull requests

As of 2026-11-12. `fork/status.sh` and
`gh pr list --repo jonwiggins/optio --author ttbeast10` are the truth.

| Branch                                  | Upstream     | Note                                                              |
| --------------------------------------- | ------------ | ----------------------------------------------------------------- |
| `fix/workspace-creation-race`           | #801         | Shares a function with #766: the second to merge needs the fixup. |
| `feat/gitlab-host-picker`               | #802         |                                                                   |
| `feat/pod-per-run`                      | #803         | Adds a migration; renumber on rebase if another lands first.      |
| `feat/deployment-admins-all-workspaces` | #766         | See #801.                                                         |
| `feat/workspace-scoped-config`          | #768         | Adds a migration.                                                 |
| `feat/jenkins-trigger`                  | not opened   | Carries a stray `helm-0.4.tar.bz2`; remove it first.              |
| `feat/jenkins-ci`                       | waits        | Stacked on `feat/jenkins-trigger`. Adds a migration.              |
| Jira Data Center                        | #767, merged | In `main`; nothing left to do.                                    |
