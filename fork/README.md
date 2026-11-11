# Managing this fork

This fork (`ttbeast10/optio-fork`) exists to send clean pull requests to
upstream (`jonwiggins/optio`) and to test several of them together as one
air-gap build before they go upstream. Nothing in `fork/` or `deploy/airgap/`
ever goes into an upstream pull request.

## The branches

| Branch                | What it is                                                                                           | Who writes it                  |
| --------------------- | ---------------------------------------------------------------------------------------------------- | ------------------------------ |
| `main`                | A mirror of upstream `main`. No commits of its own.                                                  | `fork/sync.sh` only            |
| `feat/...`, `fix/...` | A topic branch: one change, based on `main`, one upstream pull request.                              | you                            |
| `fork/overlay`        | Everything fork-only: `fork/` (these tools) and `deploy/airgap/` (bundle, deploy, check).            | you                            |
| `fork/combined`       | `main` + every branch in `fork/branches.txt` + `fork/overlay`. Images and bundles are built from it. | `fork/integrate.sh` only       |
| `backup/<date>/...`   | Snapshots taken before a branch was rewritten.                                                       | nobody; delete when not needed |

Rules:

1. All work happens on a topic branch. A bug found while testing the combined
   build is fixed on the topic branch it belongs to, then the combined branch
   is rebuilt. Never commit to `fork/combined`.
2. A topic branch touches nothing under `fork/` or `deploy/airgap/`.
3. A large change split into small pull requests is a **stack**: part 2 is
   based on part 1 (`<branch> after <parent>` in `branches.txt`). Upstream
   takes a stack one pull request at a time: open part 2 once part 1 is
   merged, after `git rebase --onto upstream/main <old part 1 tip> <part 2>`.
4. When upstream merges a pull request, remove its line from `branches.txt`.

## The commands

Run them from a checkout of `fork/overlay` (or of `fork/combined`, which
contains it).

```bash
fork/sync.sh                 # fast-forward main to upstream, then the report below
fork/status.sh               # per branch: based on main? applies alone? clean PR? merged?
fork/integrate.sh --push     # rebuild fork/combined from branches.txt
fork/pr.sh <branch>          # open the upstream pull request for one branch
```

`status.sh` columns: `BASE` (`behind N` = rebase it), `ALONE` (`CONFLICT` =
it no longer applies to `main` by itself), `PR` (`DIRTY` = it touches
fork-only files or adds a large file), `STATE` (`merged upstream` = drop it
from the list).

`integrate.sh` builds in a throwaway worktree. When two branches conflict it
stops and tells you which; resolve in that worktree, commit, and run it with
`--continue`. Each resolution is remembered (`git rerere`) and re-learned
from the previous `fork/combined`, so it is made once.

Two branches can also merge without a conflict and still break each other
(one renames a function the other calls). `git` cannot see that; the
typecheck and tests of `fork/combined` do. The repair goes in
`fork/fixups/<nn>-<name>.patch` (a `git diff` with a few lines on top saying
which branches it is for). `integrate.sh` applies every patch after the topic
branches. When one of the two pull requests is merged upstream, the other
must carry the change itself, and the patch is deleted.

After every rebuild, check the combined code before bundling it:

```bash
git checkout fork/combined && pnpm install
pnpm turbo typecheck && pnpm knip && pnpm turbo test
pnpm --filter @optio/api test:integration
```

Then build, deploy and check the bundle from the combined branch, as
`deploy/airgap/README.md` describes:

```bash
git checkout fork/combined
deploy/airgap/bundle.sh 0.25.0-fork.2 --tar
```

## Day to day

1. `git checkout -b feat/my-change origin/main`, work, push.
2. Add the branch to `fork/branches.txt` (on `fork/overlay`), push, then
   `fork/integrate.sh --push`.
3. Bundle and deploy `fork/combined`; look at it in the cluster.
4. `fork/pr.sh feat/my-change` when it is good.
5. Upstream moved: `fork/sync.sh`, rebase what it flags
   (`git rebase upstream/main`, `git push --force-with-lease`), integrate again.

## Branch names that still need tidying

Two rebased branches sit under temporary names, because the session that
rebased them was not allowed to overwrite the originals:

- `airgap/main-rebased` is `feat/deployment-admins-all-workspaces` on current `main`.
- `feat/workspace-scoped-config-rebased` is `feat/workspace-scoped-config` on current `main`.

To put them under their real names (the old tips are in `backup/2026-11-11/`):

```bash
git push --force-with-lease origin origin/airgap/main-rebased:refs/heads/feat/deployment-admins-all-workspaces
git push --force-with-lease origin origin/feat/workspace-scoped-config-rebased:refs/heads/feat/workspace-scoped-config
```

then use those names in `branches.txt` and delete the temporary branches.
`airgap/main` (the old, hand-merged combined branch) and
`claude/gitlab-hosts-pod-per-session-somjrh` are superseded by `fork/combined`.
