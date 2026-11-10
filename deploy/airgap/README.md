# Air-gap bundle: build, carry, deploy, check

A small, self-contained way to take **this checkout** into a network with no
internet access, and to rehearse that on a laptop first.

| Script               | Where it runs                | What it does                                                                |
| -------------------- | ---------------------------- | --------------------------------------------------------------------------- |
| `bundle.sh`          | connected machine, in a repo | builds the images, pulls the chart's third-party ones, writes the bundle    |
| `deploy.sh`          | the target, in the bundle    | verifies checksums, loads the images, `helm upgrade --install`              |
| `skip-setup.sh`      | the target, in the bundle    | stores a git token and an agent key through the API (no setup wizard)       |
| `check.sh`           | the target, in the bundle    | verifies the install: pods, images, offline switches, this build's features |
| `values.airgap.yaml` | —                            | the chart values `deploy.sh` applies                                        |

This sits beside the heavier upstream kit (`docs/air-gapped.md`,
`scripts/offline/`, `deploy/zarf/`), which also lets you **rebuild** images
inside the air gap. This bundle only carries images built outside.

## 1. Build the bundle (connected machine)

Needs Docker (BuildKit) and this repository at the commit you want.

```bash
git fetch origin claude/gitlab-hosts-pod-per-session-somjrh
git checkout claude/gitlab-hosts-pod-per-session-somjrh

deploy/airgap/bundle.sh 0.25.0-fork --tar
# → release/optio-airgap-0.25.0-fork/  and  release/optio-airgap-0.25.0-fork.tar
```

Options worth knowing (`--help` lists all):

- `--platform linux/amd64` — on an ARM laptop (Apple Silicon) building for an
  x86 cluster. Without it the images match the laptop, which is what a local
  rehearsal on that laptop needs. Build twice if you need both.
- `--presets node,python` — language preset agent images besides the base one.
- `--agent-clis claude-code,opencode` — a smaller agent image.
- `--with-helm` — put a `helm` binary (linux/amd64) in the bundle's `tools/`.

The first build takes a while (the agent image installs every agent CLI) and
the bundle is a few GB. `BUNDLE.txt` records the commit and the image list;
`SHA256SUMS` covers every file.

## 2. Deploy (the target)

Copy the directory (or the `.tar`) across, then from inside it:

```bash
./deploy.sh --dry-run                       # prints the helm command, changes nothing
./deploy.sh --load docker                   # Docker Desktop Kubernetes (default)
./deploy.sh --load kind                     # kind   (kind:<cluster> for a named one)
./deploy.sh --load k3d                      # k3d    (k3d:<cluster>)
./deploy.sh --load minikube
./deploy.sh --load k3s                      # k3s on this machine (sudo k3s ctr images import)
./deploy.sh --load registry:registry.corp.local/optio   # a real air gap: push, then pull
```

Needs `kubectl` and `helm` on that machine (and `docker`, plus `kind` / `k3d` /
`minikube` for those modes). Running it again upgrades: the encryption key
and the database password are read back from the cluster, so stored secrets
keep opening.

What it turns on for an air gap (`values.airgap.yaml`): no release check
(`updates.check: false`), the agent CLIs' telemetry and self-update off
(`agent.offline: true`), no outside images or links in the UI
(`web.offline: true`), and image pulls that never ask a registry when the
images were loaded straight into the node.

Things you will want to pass:

```bash
./deploy.sh --load kind \
  --gitlab-hosts gitlab.corp.local,git.lab.local \   # your GitLab servers (GITLAB_HOSTS)
  --pod-scope run \                                   # a pod per run, for every repo
  --public-url http://localhost:30310
```

- `--gitlab-hosts` is what makes the **GitLab server picker** show two buttons
  (Repos → Add Repository → GitLab). The hosts are also added to the API's
  outbound allow-list. Each server's token is a secret named
  `GITLAB_TOKEN_<HOST>` (`GITLAB_TOKEN_GIT_LAB_LOCAL` for `git.lab.local`),
  else `GITLAB_TOKEN`.
- `--pod-scope run` sets the deployment default; a single repo can still say
  otherwise in its settings (Pods → Pod scaling). See `docs/pod-scope.md`.
- `--env NAME=value` passes any API environment variable the chart has no
  value for, e.g. `--env GITLAB_OAUTH_BASE_URL=https://gitlab.corp.local`.
- `--values my.yaml` for everything else the chart takes: ingress, storage
  classes, Jenkins (`jenkins.url`, `jenkins.user`), a private CA.
- `--release <name>` when the Helm release isn't called `optio` (its
  Deployment is `<name>-api`, its keys are read back from `<name>-config` and
  `<name>-postgres-credentials`); give `check.sh` the same `--release`.

By default the web is at <http://localhost:30310> and the API at
<http://localhost:30400> (NodePorts). kind and k3d only expose those if the
cluster was created with the port mappings; otherwise:

```bash
kubectl -n optio port-forward svc/optio-web 30310:3000 &
kubectl -n optio port-forward svc/optio-api 30400:4000 &
```

## 3. Getting past the setup page

Two separate gates, and how the browser tests earlier got past both:

1. **Sign-in.** `deploy.sh` defaults to `--auth disabled`: no login at all,
   everyone is a local admin. That is for a rehearsal on your own machine
   only — never on a shared network.
2. **The setup wizard.** The web redirects to `/setup` until
   `GET /api/setup/status` says `isSetUp: true`, which needs exactly two
   things stored as secrets: **one git token** (`GITLAB_TOKEN` or
   `GITHUB_TOKEN`) and **one agent credential** (`ANTHROPIC_API_KEY`,
   `CLAUDE_CODE_OAUTH_TOKEN`, `OPENAI_API_KEY`, `GEMINI_API_KEY`,
   `OPENCODE_DEFAULT_BASE_URL`, …). Nothing else gates it.

So either walk the wizard, or store the two secrets directly:

```bash
GITLAB_TOKEN=glpat-xxxx ANTHROPIC_API_KEY=sk-ant-xxxx ./skip-setup.sh
# a second GitLab server's own token:
GITLAB_TOKEN_GIT_LAB_LOCAL=glpat-yyyy ./skip-setup.sh
```

For a rehearsal with no real services behind it, placeholder values get you
past the page too; listing projects and running agents then fail until real
values replace them (Settings → Secrets).

### With real sign-in (what the air gap should run)

```bash
./deploy.sh --load registry:registry.corp.local/optio --auth setup-token \
  --public-url https://optio.corp.local --values sign-in.yaml
```

`sign-in.yaml` names your provider. A self-managed GitLab is an OpenID
Connect provider, so the generic OIDC block works (register
`<public-url>/api/auth/oidc/callback` as the redirect URI in GitLab, scopes
`openid profile email`):

```yaml
auth:
  oidc:
    issuerUrl: https://gitlab.corp.local
    clientId: "<application id>"
    clientSecret: "<secret>"
    displayName: GitLab
```

or GitLab's own OAuth flow: `auth.gitlab.clientId` / `clientSecret` in the
values plus `--env GITLAB_OAUTH_BASE_URL=https://gitlab.corp.local`.

`--auth setup-token` prints a one-time **setup token**. With no provider
configured it unlocks the setup page's Sign-in step; with one configured, the
first person to sign in becomes the deployment admin. `skip-setup.sh` then
needs `OPTIO_TOKEN` set to that admin's personal access token.

## 4. Check

```bash
./check.sh                      # --namespace / --release if not optio
```

It verifies, and exits non-zero on a failure:

- the deployment is rolled out, every pod is running, no image pull failed;
- every image in the namespace is one of the bundle's (`images.txt`);
- `/api/health` answers, and whether setup is complete;
- the offline switches are on (`OPTIO_UPDATE_CHECK=false`,
  `OPTIO_AGENT_OFFLINE=true`, `OPTIO_OFFLINE_UI=true`);
- this build's features are present: pod scope and Jenkins in the config
  schema, the `repos.pod_scope` and `repos.jenkins_job` columns (the
  migrations ran), and the GitLab server list from `/api/repos/browse`;
- an egress probe: a throwaway `busybox` pod tries to reach the internet and
  the script says whether this cluster actually behaves like an air gap.

Then by hand:

1. **GitLab servers** — Repos → Add Repository → GitLab: one button per host
   given to `--gitlab-hosts`; click each and see its projects.
2. **Pod per run** — open a repo → Pods → Pod scaling → _Pods are shared by_
   → _Nothing: a pod per run_ (or deploy with `--pod-scope run`), start two
   tasks on it, and watch `kubectl -n optio get pods -w`: two agent pods, one
   per task, gone about ten minutes after they go idle.
3. **Jenkins** — a `jenkins` trigger on a piece of work, and a repo's
   _Jenkins job_ field (`docs/jenkins.md`).

## Making the rehearsal honest

A laptop cluster usually has internet access, so a forgotten runtime download
would still succeed there. `check.sh` tells you when that is the case. To
close it: turn the network off after `deploy.sh` finishes loading, or create
the kind / k3d cluster on a Docker network with no route out.

## Limits

- The chart's Postgres and Redis init containers use `busybox:1.36` by that
  exact name. The bundle carries it and node-loaded clusters find it; with
  `--load registry:…` the cluster's runtime must be able to resolve
  `busybox:1.36` (a registry mirror for docker.io, or the image preloaded on
  the nodes).
- Agent pods need what they need at run time: your GitLab, your model
  endpoint, your package mirrors. With `networkPolicy.enabled` list them in
  `networkPolicy.internalEgress` (`docs/air-gapped.md`).
- Removing it: `helm uninstall optio -n optio` (volumes stay until their PVCs
  are deleted).
