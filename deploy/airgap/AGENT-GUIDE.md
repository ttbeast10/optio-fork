# Guide for the local agent: sync with upstream, bundle, deploy, check

You are working on a laptop, in a clone of the fork `ttbeast10/optio-fork`
(upstream: `jonwiggins/optio`). Your job, in order: bring the fork's branches
up to date with upstream, push them, build the air-gap bundle from the
combined branch, deploy it to the local Kubernetes cluster, and verify it.
Read `AGENTS.md` first (worktrees, hooks, test tiers), then
`deploy/airgap/README.md`.

## What exists

| Branch                                         | What                                             | PR on the fork |
| ---------------------------------------------- | ------------------------------------------------ | -------------- |
| `feat/jenkins-trigger`                         | Jenkins builds start work                        | #1             |
| `feat/jenkins-ci` (stacked on jenkins-trigger) | Jenkins builds as a repo's CI checks             | #2             |
| `feat/gitlab-host-picker`                      | Add Repository: pick between GitLab servers      | #3             |
| `feat/pod-per-run`                             | Pod scope: a pod per run                         | #4             |
| `claude/gitlab-hosts-pod-per-session-somjrh`   | **combined**: all four merged + `deploy/airgap/` | none           |

All of them were cut from upstream `main` at `7d6183b`, which is the commit
upstream tagged **v0.25.0**. `CHANGELOG.md` there still has 0.24.2 as its
newest heading; that is upstream's own state, not a sign the fork is behind.
Upstream may have moved since. Step 1 finds out and acts on it.

GitLab sign-in, generic OIDC and several GitLab hosts (`GITLAB_HOSTS`,
`GITLAB_TOKEN_<HOST>`) are already in upstream `main`; they need no branch.

## Rules

- Never push to `jonwiggins/optio`. Never merge or close a PR. Never push to
  the fork's `main` except the fast-forward in step 1.
- Rebased branches are pushed with `--force-with-lease`, never `--force`.
- Run `pnpm check:push` before each push and let the hooks run. This machine
  has Docker and Playwright, so do not use `--no-verify`. (The commits you
  are inheriting were pushed with it from a sandbox that could not run the
  browser suite; this is the first full run.) If a check fails, fix the
  cause; do not skip or weaken a test.
- Secrets go in environment variables or files, never on a command line, in
  a commit, or in your report.
- Stop and ask the user when: a rebase conflict is not one of the expected
  ones below and its resolution changes behaviour; a suite fails for a
  reason you cannot trace to the rebase; the cluster already has an `optio`
  namespace you did not create; or anything would delete data.

## Step 0: preflight

```bash
docker info >/dev/null && kubectl config current-context && helm version --short
node --version && pnpm --version          # the repo wants the Node in .nvmrc / package.json engines
git remote -v
```

Find out which local cluster this is (Docker Desktop, kind, k3d, minikube):
it decides `--load` in step 3. Note the machine's CPU architecture
(`uname -m`) and ask the user what the air-gapped cluster runs if you do not
know; an ARM laptop building for an x86 cluster needs
`--platform linux/amd64` for the bundle that will actually be carried over.

## Step 1: sync with upstream, rebase, push

```bash
git remote add upstream https://github.com/jonwiggins/optio 2>/dev/null || true
git fetch upstream --tags
git fetch origin
git rev-parse upstream/main origin/main
git describe --tags upstream/main
```

**If `upstream/main` equals `origin/main`:** there is nothing to rebase. Say
so and go to step 2.

**If upstream is ahead:**

1. Fast-forward the fork's `main` (it carries no commits of its own; if it
   does not fast-forward, stop and ask):
   `git push origin upstream/main:main`
2. Rebase each branch in its own worktree, in this order, and after each one
   run `pnpm install`, then `pnpm check:push`, then
   `git push --force-with-lease`:
   - `feat/jenkins-trigger` onto `upstream/main`
   - `feat/jenkins-ci` onto the rebased `feat/jenkins-trigger`
     (`git rebase --onto feat/jenkins-trigger <old jenkins-trigger tip> feat/jenkins-ci`)
   - `feat/gitlab-host-picker` onto `upstream/main`
   - `feat/pod-per-run` onto `upstream/main`
3. Rebuild the combined branch rather than rebasing its merges: note the tip
   of the `deploy/airgap` commit(s)
   (`git log --oneline origin/claude/gitlab-hosts-pod-per-session-somjrh -- deploy/airgap`),
   then reset the branch to the rebased `feat/jenkins-ci`, merge
   `feat/gitlab-host-picker`, merge `feat/pod-per-run`, cherry-pick the
   `deploy/airgap` commits, run `pnpm check:push --full`, and push with
   `--force-with-lease`.

Expected conflicts and how to resolve them:

- `CHANGELOG.md`: keep every entry, under one `### Added` in `[Unreleased]`.
- `apps/api/src/db/migrations/meta/_journal.json`: keep upstream's entries,
  then `1795100000_repo_jenkins_job`, then `1795200000_repo_pod_scope`, with
  `idx` counting up without gaps. `feat/jenkins-ci` and `feat/pod-per-run`
  each append one entry at the same index on their own; only the combined
  branch has both. If upstream added a migration with a **later** timestamp
  than these two, rename ours (file, journal `tag` and `when`) to timestamps
  after upstream's newest, since they are not released anywhere. Then run
  `bash scripts/check-migration-prefixes.sh` and
  `pnpm --filter @optio/api exec vitest run src/db/migrations`.
- `apps/api/src/services/slack-service.test.ts`: the repo fixture needs both
  `jenkinsJob: null` and `podScope: null`.
- `apps/api/src/routes/repos.ts`, `apps/api/src/schemas/config.ts`,
  `apps/web/src/app/repos/[id]/page.tsx`, `helm/optio/values.yaml`,
  `helm/optio/templates/secrets.yaml`, `AGENTS.md`: both sides add
  independent fields or lines; keep both.

One open question to raise with the user, not to decide yourself:
`feat/jenkins-trigger` contains a stray `helm-0.4.tar.bz2` at the repo root.

After pushing, check each PR's CI run for the pushed SHA
(`gh run list --workflow CI --commit <sha>`) and report its result; do not
call anything green while a run is pending.

## Step 2: build the bundle

From the combined branch, at the commit you just pushed:

```bash
git checkout claude/gitlab-hosts-pod-per-session-somjrh
VERSION="$(git describe --tags --abbrev=0 upstream/main | sed 's/^v//')-fork"   # e.g. 0.25.0-fork
deploy/airgap/bundle.sh "$VERSION" --tar
```

That is the rehearsal bundle (this machine's architecture). The first build
is slow and the result is several GB. `release/` is git-ignored.

These scripts have passed `shellcheck` and a dry run against stand-in
`docker` / `kubectl` / `helm` commands, but have **never run against the
real tools**. Expect to find a bug or two. Fix them in `deploy/airgap/`,
commit to the combined branch with a conventional commit message, and push.
Rebuild the bundle after a fix so the copy inside it matches.

## Step 3: deploy

```bash
cd release/optio-airgap-$VERSION
./deploy.sh --dry-run
helm lint ./chart -f values.airgap.yaml --set encryption.key=$(openssl rand -hex 32) \
  --set postgresql.auth.password=x --set auth.disabled=true
```

Ask the user for their two GitLab hostnames (or use two placeholder names
for a pure UI check), then:

```bash
./deploy.sh --load <docker|kind|k3d|minikube> \
  --gitlab-hosts <host-a>,<host-b> --pod-scope run
```

If the web is not reachable on <http://localhost:30310> (kind and k3d need
port mappings), use the two `kubectl port-forward` lines from the README.

## Step 4: get past the setup page

Sign-in is off in this rehearsal (`--auth disabled`). The setup page then
only waits for one git token and one agent credential to exist as secrets.
Ask the user for real values, or use placeholders when no real GitLab or
model endpoint is reachable:

```bash
GITLAB_TOKEN=... ANTHROPIC_API_KEY=... ./skip-setup.sh
```

## Step 5: check

```bash
./check.sh
```

Every line should be `ok`. `note` lines are information: read them,
especially the egress one. If pods can reach the internet, say so in your
report: the rehearsal then cannot prove nothing downloads at run time. If the
user wants that proven, cut the network after the images are loaded and run
`./check.sh` again.

Then verify the features in the browser (use the Playwright the repo
already has, or ask the user to look):

1. **GitLab servers**: Repos → Add Repository → GitLab shows one button per
   host from `--gitlab-hosts`; clicking each switches the list (with
   placeholder tokens the list is an error message, which is fine: the
   buttons and the switch are what is being checked).
2. **Pod per run**: add a repo, start two tasks on it, and run
   `kubectl -n optio get pods -w`. With `--pod-scope run` each task gets its
   own agent pod. Then set that repo to _The repo_ under Pods → Pod scaling,
   start two more, and confirm they share one. Real agent runs need a real
   model credential and a reachable git server; without them, confirm the
   pod is created per task and say the agent itself could not run.
3. **Jenkins**: the work form offers a Jenkins trigger; a repo's settings
   have a _Jenkins job_ field.

## Step 6: report

Tell the user, plainly:

- whether upstream had moved, what was rebased, and the pushed SHAs;
- `pnpm check:push` and CI results per branch, with the failing output for
  anything that failed;
- the bundle path, size, version and architecture;
- `check.sh` output, and which manual checks passed, failed, or could not be
  done and why;
- every change you made to `deploy/airgap/` and why;
- what still stands between this rehearsal and the real air gap: the
  amd64 bundle if this one is ARM, real sign-in (`--auth setup-token` with
  the GitLab OIDC values in the README), the registry mode
  (`--load registry:<prefix>`, where `busybox:1.36` must resolve), and the
  agent network policy lists.

Leave the deployment running unless the user asks for it to be removed
(`helm uninstall optio -n optio`).
