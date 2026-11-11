feat(pods): pod scope — a pod per run instead of the repo's shared pod

## Summary

A repo's runs share its long-lived pod (a worktree each), so whether a new run starts a new pod depends on what else is running on that repo. This adds an opt-in **pod scope `run`**: every task and PR review gets a pod of its own, with its own clone, that no other run uses. The default (`repo`) is unchanged.

## Changes

**How it works**

- `PodIsolation` gains `runId`. When set, it joins the pod's isolation key, so the pool (`pickPod`) finds that pod again for the same run's retries and resumes and never for another run. When unset the key is byte-for-byte what it was, so existing pods keep matching (pinned by a test).
- `resolvePodScope(repo.podScope)`: the repo's setting, else `OPTIO_POD_SCOPE`, else `repo`. The task worker and the PR-review worker pass `runId` when the scope is `run`.
- A run's pod keeps nothing: no home PVC on bare pods (ephemeral storage), `persistentVolumeClaimRetentionPolicy: Delete` on its StatefulSet, no shared cache volume. Idle cleanup removes it like any repo pod (`OPTIO_REPO_POD_IDLE_MS`).

**Where it is set**

| Level          | How                                                                                                                                                 |
| -------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| Repo           | repo settings → Pods → Pod scaling → _Pods are shared by_; `PATCH /api/repos/:id { "podScope": "run" \| "repo" \| null }`; column `repos.pod_scope` |
| Config as code | `podScope: run` in a `Repo` manifest                                                                                                                |
| Deployment     | Helm `agent.podScope` → `OPTIO_POD_SCOPE`                                                                                                           |

**Files**: `services/pod-isolation.ts`, `repo-pool-service.ts`, `k8s-workload-service.ts`, both workers, schema + migration `1795200000_repo_pod_scope`, repo route and manifest schemas, repo settings page, Helm values / secrets template, `docs/pod-scope.md`, AGENTS.md, CHANGELOG.

**Deliberately unchanged**

- Limits: `maxPodInstances × maxAgentsPerPod` (and `maxConcurrentTasks`, `OPTIO_MAX_CONCURRENT`) still cap how many runs are in flight, which under `run` is also the pod count.
- Interactive sessions (already a pod each), Jobs (pods per Job, not per repo) and persistent agents (a pod per agent) are not covered.

## Testing

- `pod-isolation.test.ts`: the shared key is unchanged, a key per run, scope precedence.
- `e2e/pod-per-run.e2e.test.ts` (real API server, fake runtime): two tasks on one repo share a pod by default; with `podScope: run` they run in different pods; clearing it shares again.

Run locally and passing: lint, knip, typecheck, prettier, migration prefix check, unit tests (API `--changed` 195 files, web all 151), the **full** API integration tier (103 files, applies the migration) and the full API e2e tier (38 files).

- [ ] `pnpm check:push` passes — **not run as a whole**: no Firefox / matching Chromium in the sandbox, so the browser suite did not run and the push skipped the local hook. `helm` was not available either: the chart change is one value and one env line, but `pnpm check:infra` has not run. Not exercised on a real cluster: PVC deletion with StatefulSets relies on `persistentVolumeClaimRetentionPolicy` (on by default from Kubernetes 1.27).

## Related

Migration ordering: a separate Jenkins-as-CI change (not yet opened here) also adds a migration at journal index 141. Whichever merges second needs its journal entry renumbered.

## Screenshots

None taken of the repo settings control.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_018eB9e7utYdRjcHXZ7PEB3d
