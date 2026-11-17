# Guide for the local session

You are working on the owner's own machine, in a clone of the fork
`ttbeast10/optio-fork` (upstream: `jonwiggins/optio`). This machine has what
the cloud sessions that prepared this did not: Docker, a local k3s cluster,
the Playwright browsers, and a signed-in `gh`. Your job is the part that
needs them.

Read first: `AGENTS.md` (worktrees, hooks, test tiers), `fork/README.md`
(how the branches are organised), `deploy/airgap/README.md` (bundle, deploy,
check).

## The goal

1. Finish tidying the fork's branches.
2. Open the pull requests on upstream.
3. Build the combined branch into an air-gap bundle, deploy it to the local
   k3s, check it, and leave it running so the owner can browse it.
4. Report.

## Where things stand (2026-11-11)

Upstream `main` is `7d6183b` (tagged v0.25.0) and the fork's `main` equals it.

| Branch                                 | What                                                    | State                                                     |
| -------------------------------------- | ------------------------------------------------------- | --------------------------------------------------------- |
| `fix/workspace-creation-race`          | One Default workspace when first requests race          | ready for upstream                                        |
| `feat/gitlab-host-picker`              | Add Repository: pick between GitLab servers             | ready for upstream                                        |
| `feat/pod-per-run`                     | Pod scope: a pod per run                                | ready for upstream                                        |
| `feat/jenkins-trigger`                 | Jenkins builds start work                               | has a stray `helm-0.4.tar.bz2` at the repo root (step 1)  |
| `feat/jenkins-ci`                      | Jenkins builds as CI checks                             | stacked on `feat/jenkins-trigger`; goes upstream after it |
| `airgap/main-rebased`                  | Deployment admins as admins of every workspace          | temporary name (step 1)                                   |
| `feat/workspace-scoped-config-rebased` | Workspace-scoped configuration                          | temporary name (step 1)                                   |
| `fork/overlay`                         | `fork/` and `deploy/airgap/`: fork-only, never upstream | —                                                         |
| `fork/combined`                        | `main` + all of the above; generated                    | built and pushed at `8ba98bf` or later                    |

Already done, do not redo: `feat/jira-data-center` is in upstream `main`.
`backup/2026-11-11/*` are snapshots of every branch that was rewritten.
`airgap/main`, `claude/gitlab-hosts-pod-per-session-somjrh`,
`ccr-2db9ad54-rocst0` and the old `feat/deployment-admins-all-workspaces` /
`feat/workspace-scoped-config` / `feat/jira-data-center` tips are superseded.

What the cloud session verified on `fork/combined`: typecheck, lint, knip,
the API and web unit suites, the whole API integration tier (782 tests) and
the whole API e2e tier (166 tests). **Never run anywhere yet:** the browser
suite, an image build, `deploy/airgap/*.sh` against real Docker / Kubernetes
/ Helm. Expect to find a bug or two there.

Two branches need each other's attention: `fix/workspace-creation-race` and
the deployment-admins branch merge cleanly but do not compile together.
`fork/fixups/10-workspace-race-with-deployment-admins.patch` repairs the
combined branch. Upstream, whichever of the two is merged second must carry
that change itself: after the first merges, rebase the other onto
`upstream/main`, apply the patch to it, and delete the patch from
`fork/fixups/`.

## Rules

- Never push to `jonwiggins/optio`. Never merge or close a pull request.
  The fork's `main` only ever fast-forwards to upstream (`fork/sync.sh`).
- A rewritten branch is pushed with `--force-with-lease`, never `--force`.
- Never commit to `fork/combined`: fix the topic branch (or
  `fork/overlay` for anything under `fork/` or `deploy/airgap/`), then
  `fork/integrate.sh --push`.
- A topic branch carries nothing under `fork/` or `deploy/airgap/`.
- Let the hooks run: `pnpm check:push` before each push of a topic branch,
  no `--no-verify`. (The commits you inherit were pushed with it from a
  sandbox that could not run the browser suite.) If a check fails, fix the
  cause; do not skip or weaken a test.
- Secrets go in environment variables or files, never on a command line, in
  a commit, or in your report.
- Stop and ask the owner when: a conflict's resolution changes behaviour;
  a suite fails for a reason you cannot trace; the cluster already has the
  namespace you are about to deploy into and you did not create it; or
  anything would delete data or a branch not listed for deletion below.

## Step 0: preflight

```bash
docker info >/dev/null && kubectl config current-context && helm version --short
node --version && pnpm --version     # the Node in .nvmrc / package.json engines
gh auth status
git remote -v && git fetch origin --prune
git worktree add ../optio-fork-tools origin/fork/overlay && cd ../optio-fork-tools
```

Work from that worktree: every `fork/…` command below runs there. Note the
CPU architecture (`uname -m`); ask the owner what the air-gapped cluster
runs if you do not know.

## Step 1: tidy the branches

1. Put the two rebased branches under their real names, then use those names
   in `fork/branches.txt` (commit on `fork/overlay`, push) and delete the
   temporary branches:

   ```bash
   git push --force-with-lease origin origin/airgap/main-rebased:refs/heads/feat/deployment-admins-all-workspaces
   git push --force-with-lease origin origin/feat/workspace-scoped-config-rebased:refs/heads/feat/workspace-scoped-config
   # edit fork/branches.txt, commit, push fork/overlay, then:
   git push origin --delete airgap/main-rebased feat/workspace-scoped-config-rebased
   ```

2. `feat/jenkins-trigger` contains `helm-0.4.tar.bz2` at the repo root. Ask
   the owner whether it is a mistake. If it is: remove it in a new commit on
   `feat/jenkins-trigger`, then rebase `feat/jenkins-ci` onto it
   (`git rebase --onto feat/jenkins-trigger <old trigger tip> feat/jenkins-ci`),
   `pnpm check:push` and push both.
3. Ask the owner before deleting the superseded branches listed above
   (keep `backup/2026-11-11/*` until the bundle has been deployed and checked).
4. `fork/sync.sh` — expect every branch `ok / ok / clean`. If upstream has
   moved, rebase what it flags (stacks parent first), `pnpm check:push`,
   push with `--force-with-lease`.
5. `fork/integrate.sh --push`, then check the combined branch in full, with
   the browser suite this time:

   ```bash
   git worktree add ../optio-fork-combined origin/fork/combined
   cd ../optio-fork-combined && pnpm install && pnpm check:push --full
   ```

   A failure here is either one branch's own bug (fix it on that branch) or
   two branches breaking each other (a `fork/fixups/` patch; see
   `fork/README.md`). Rebuild and repeat until it passes.

## Step 2: open the upstream pull requests

The owner has asked for these to be opened. Each needs CI-equivalent checks
to have passed on this machine first (`pnpm check:push` on the branch).

```bash
fork/pr.sh fix/workspace-creation-race     # the important one: open it first
fork/pr.sh feat/gitlab-host-picker
fork/pr.sh feat/pod-per-run
fork/pr.sh feat/jenkins-trigger            # only after step 1.2
```

`fork/pr.sh` refuses a branch that is behind upstream or touches fork-only
files, and uses the title and description in `fork/pr/<branch>.md`. Tick the
`pnpm check:push` box in the description only if it passed here.

- `feat/deployment-admins-all-workspaces` and `feat/workspace-scoped-config`
  have no description yet. Write `fork/pr/<branch>.md` for each from the
  commits and the docs they add (first line the title, then upstream's
  template: Summary, Changes, Testing, Related), show them to the owner,
  then `fork/pr.sh`. In the deployment-admins description, say that it and
  the workspace-creation-race fix touch the same function and the second to
  merge needs a small follow-up (the fixup patch).
- `feat/jenkins-ci` waits until `feat/jenkins-trigger` is merged upstream.
- Three branches each add a migration at the next journal index (Jenkins CI,
  pod per run, workspace-scoped config). Only the first to merge keeps it;
  the others are renumbered when rebased (journal `idx`, and a timestamp
  later than upstream's newest).

After opening, give the owner the pull request URLs. Check each one's CI
(`gh pr checks <url>`) and report the result; never call a run green while
it is pending.

## Step 3: bundle

From the `fork/combined` worktree, at the commit you pushed:

```bash
deploy/airgap/bundle.sh 0.25.0-fork.2 --tar        # → release/optio-airgap-0.25.0-fork.2/
```

This is the rehearsal bundle, for this machine's architecture. The first
build is slow and the result is several GB; `release/` is git-ignored. Fix
any script bug in `deploy/airgap/` on `fork/overlay`, re-run
`fork/integrate.sh --push`, and rebuild so the copy inside the bundle
matches.

**The organisation's CA.** The earlier images went out without it and pods
failed against GitLab / Harbor with `SELF_SIGNED_CERT_IN_CHAIN`. The file
that added it (`ca/Dockerfile.agent-ca`) was never in this repository. Ask
the owner for it (or for the CA certificate). Add the layer under
`deploy/airgap/` so `bundle.sh` applies it to every image
(`NODE_EXTRA_CA_CERTS` set, certificate in the system trust store). A
bundle without it is fine for this rehearsal; **do not hand over a bundle
for the real air gap without it**, and say in the report which kind you built.

## Step 4: deploy to k3s

```bash
cd release/optio-airgap-0.25.0-fork.2
./deploy.sh --dry-run
./deploy.sh --load k3s --namespace optio-preview --release optio-preview \
  --gitlab-hosts <host-a>,<host-b> --pod-scope run
```

Use a namespace of its own, so a real Optio on the same machine is not
touched. Ask the owner for the GitLab hostnames, and for the ingress they
use in the air gap (host, class, TLS): pass it as `--values <file>` with
`--public-url`, so the web UI is reachable the same way it will be there.
Without ingress, use the port-forward lines in `deploy/airgap/README.md`.

Sign-in is off in the rehearsal (`--auth disabled`). The setup page then
waits for one git token and one agent credential:

```bash
GITLAB_TOKEN=... ANTHROPIC_API_KEY=... ./skip-setup.sh     # real values from the owner, or placeholders
```

## Step 5: check

```bash
./check.sh --namespace optio-preview --release optio-preview
```

Every line should be `ok`; read the `note` lines, the egress one above all.
Then look at the features in the browser (the repo's Playwright, or ask the
owner):

1. **One workspace**: with real sign-in (`--auth setup-token`) a first
   sign-in creates exactly one workspace. With sign-in off, say this was not
   exercised live.
2. **GitLab servers**: Repos → Add Repository → GitLab shows a button per host.
3. **Pod per run**: two tasks on one repo get a pod each
   (`kubectl -n optio-preview get pods -w`); set the repo back to _The repo_
   and they share one.
4. **Jenkins**: the work form offers a Jenkins trigger; a repo's settings
   have a _Jenkins job_ field.
5. **Deployment admins**: Settings → Access has _Admins of every workspace_.
6. **Workspace-scoped configuration**: a second workspace does not see the
   first one's organization secrets.

Leave the deployment running and give the owner its URL.

## Step 6: report

Tell the owner, plainly:

- what was renamed, rebased, deleted, and the pushed SHAs;
- `pnpm check:push --full` on `fork/combined`, with the failing output for
  anything that failed, and what you fixed where;
- each upstream pull request's URL and CI state, and which were not opened and why;
- the bundle's path, size, version, architecture, and whether it has the CA layer;
- `check.sh` output, and which browser checks passed, failed, or could not be done;
- every change to `deploy/airgap/` and `fork/`;
- what still stands between this rehearsal and the real air gap.
