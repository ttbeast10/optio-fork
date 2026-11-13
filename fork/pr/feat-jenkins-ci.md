feat(ci): read a repo's Jenkins builds as its PRs' CI checks

## Summary

Jenkins as a repo's CI. A repo names the Jenkins job that builds it, and that job's builds of a PR's head count as the PR's CI checks. Review on CI pass, auto-resume on a failed build, and auto-merge then wait for Jenkins the way they wait for GitHub checks or a GitLab pipeline.

**Stacked on #JENKINS_TRIGGER_PR (Jenkins trigger).** Until that one is merged this diff also shows its commit; the change here is only the second commit, `feat(ci): read a repo's Jenkins builds as its PRs' CI checks`. I will rebase this onto `main` as soon as the trigger PR merges.

## Changes

**How it works**

- **Per repo**: `repos.jenkins_job` (migration `1795100000_repo_jenkins_job`), set in repo settings → **Jenkins job**, or `jenkinsJob` in a `Repo` manifest. A multibranch pipeline (its branch / PR jobs are found by themselves) or a single job.
- **Where checks come from**: `getGitPlatformForRepo` wraps the platform when the repo names a job (`withRepoJenkins`), adding Jenkins builds to `getCIChecks`. Every caller (PR watcher, reconciler, PR reviews, external PR reviews, PR panel, work-link status) gets them with no other change. Without `JENKINS_URL` there's no extra DB read.
- **Finding the build**: one `api/json?tree=` read of the job returns each branch/PR job's newest builds (or a plain job's own). A build matches the head commit via `lastBuiltRevision.SHA1`, `revision.hash`, a GitHub PR's `revision.pullHash`, or a GitLab MR's `revision.origin.hash` (merge builds). Newest build per job → one `Jenkins <job>` check.
- **Mapping**: building → in progress; `SUCCESS` → passed; `FAILURE` / `UNSTABLE` → failed; `ABORTED` → cancelled; `NOT_BUILT` → skipped.
- **Waits rather than guesses**: until Jenkins has a build of the commit, or while it can't be read, the repo has one **pending** `Jenkins` check, so a PR never auto-merges on the platform's checks alone. A commit Jenkins never builds keeps the PR waiting (documented; clear the repo's job to stop).
- **Fixing a failed build**: a CI-fix resume reads each failed / unstable build's `consoleText` tail (150 lines, masked with the existing `maskSecrets` plus the Jenkins token) and uses a Jenkins-worded prompt (no `gh` / `glab` hints). `OPTIO_CI_FAILURE_LOGS=false` turns it off.

**Security**

- Credentials go only to `JENKINS_URL`, set by the operator. A repo setting is a job _path_, validated (`utils/jenkins-job.ts`: no empty / `.` / `..` segments, no `?#\` or control characters) and encoded segment by segment; console logs are read under `JENKINS_URL` even if Jenkins reports another URL.
- Requests go through `guardedFetch` (a private Jenkins must be listed in `OPTIO_OUTBOUND_ALLOWED_HOSTS`, like a self-managed GitLab), with timeouts and no redirects.
- `JENKINS_USER` / `JENKINS_API_TOKEN`: workspace or organization secrets, else the environment (Helm `jenkins.url`, `jenkins.user`, `existingSecrets.JENKINS_API_TOKEN`); none = anonymous.

| Area | Change                                                                                                                                                                                                                          |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| API  | `services/jenkins-ci.ts` (new), `utils/jenkins-job.ts` (new), `git-token-service.ts` wrap, `resume-facts.ts` + `resume-prompts.ts` Jenkins failures, `FailedJobs.ci`, `readTail` exported, repo update + config-as-code schemas |
| DB   | `repos.jenkins_job text`                                                                                                                                                                                                        |
| Web  | Repo settings: **Jenkins job** field under the PR lifecycle                                                                                                                                                                     |
| Helm | `jenkins.url` / `jenkins.user` → `JENKINS_URL` / `JENKINS_USER`; Rancher questions                                                                                                                                              |
| Docs | `docs/jenkins.md` "Jenkins as CI"; `AGENTS.md`; CHANGELOG                                                                                                                                                                       |

## Testing

- `jenkins-ci.test.ts` (13): job paths and refusals, `JENKINS_URL` parsing, multibranch and plain trees, matching by SHA1 / `pullHash` / MR `origin.hash`, newest-per-job, check mapping, pending on no build / HTTP error / network error, the platform wrapper (merges checks, keeps every other method and `this`), failed-build console tails masked and read under `JENKINS_URL`, the Jenkins resume prompt, access from env.

LOCAL_RESULTS

## Related

Stacked on #JENKINS_TRIGGER_PR. Migration ordering: #803 (pod scope) and #768 (workspace-scoped config) also add migrations; whichever lands later gets its journal entry renumbered on rebase.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_018eB9e9aotys6ZPXY12gfhJ
