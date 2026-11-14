import { eq } from "drizzle-orm";
import { parsePrUrl, type WorldSnapshot } from "@optio/shared";
import { db } from "../db/client.js";
import { tasks } from "../db/schema.js";
import { getGitPlatformForRepo } from "./git-token-service.js";
import { fetchFailedJobLogs, type FailedJobs } from "./git-platform/gitlab-ci-logs.js";
import { fetchJenkinsFailedBuilds, jenkinsAccess, repoJenkinsJob } from "./jenkins-ci.js";
import { logger } from "../logger.js";

/**
 * What an automatic resume tells the agent beyond upstream's fixed wording
 * (reconcile-executor.ts `buildResumeContext` calls this):
 *
 * - **conflicts**: the branch to rebase onto is the MR's own target branch.
 *   Upstream says `git rebase origin/main` whatever the repo, so a repo whose
 *   MRs go to master, develop or a release branch was rebased onto the wrong
 *   branch (upstream fixed the same class at task start, #643, not here).
 *   Without an answer from the platform: the branch the task started from.
 * - **ci_failure**: the failed jobs' names, stages and the last lines of
 *   their logs, secrets masked, so the agent starts from the error instead
 *   of hunting for it — GitLab's pipeline (git-platform/gitlab-ci-logs.ts),
 *   or the repo's failed Jenkins builds (jenkins-ci.ts) when Jenkins builds
 *   it, unless `OPTIO_CI_FAILURE_LOGS=false` (`ciFailureLogsEnabled`).
 *
 * Everything here is best effort and bounded in time: the resume waits for
 * these reads at most `FACTS_TIMEOUT_MS`, well under the reconcile job's lock
 * (`OPTIO_RECONCILE_LOCK_MS`, 30 s), and on any failure goes ahead with the
 * fallback (upstream's CI wording, the task's own branch). The executor
 * re-checks the task's version after the wait, so a pass that read an older
 * snapshot doesn't resume the task a second time.
 */

export interface ResumeFacts {
  /** The branch the MR merges into (the task's branch when unknown). */
  targetBranch: string;
  /** The failed pipeline's jobs and log tails (CI resumes only; `ciFailureLogsEnabled`). */
  ciFailure?: FailedJobs | null;
}

/**
 * Whether a CI-fix resume reads the failed jobs' logs on `platform`:
 * GitLab's unless `OPTIO_CI_FAILURE_LOGS=false`; other platforms retain
 * upstream's wording. (A repo Jenkins builds reads its builds' logs on any
 * platform unless the flag is `false`: `jenkinsFailureLogsEnabled`.)
 */
export function ciFailureLogsEnabled(
  platform: string,
  env: NodeJS.ProcessEnv = process.env,
): boolean {
  const flag = (env.OPTIO_CI_FAILURE_LOGS ?? "").trim().toLowerCase();
  if (flag === "true") return platform === "gitlab";
  if (flag === "false") return false;
  return platform === "gitlab";
}

/** Whether a CI-fix resume reads failed Jenkins builds' logs: unless `OPTIO_CI_FAILURE_LOGS=false`. */
function jenkinsFailureLogsEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  return (env.OPTIO_CI_FAILURE_LOGS ?? "").trim().toLowerCase() !== "false";
}

/** How long a resume waits for these reads before using the fallback. */
export const FACTS_TIMEOUT_MS = 15_000;

export async function loadResumeFacts(
  snapshot: WorldSnapshot,
  reason: "ci_failure" | "conflicts" | "review",
): Promise<ResumeFacts> {
  const run = snapshot.run;
  const fallback: ResumeFacts = {
    targetBranch: (run.kind === "repo" && run.spec.repoBranch) || "main",
  };
  if (run.kind !== "repo" || reason === "review" || !run.status.prUrl) return fallback;
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error("timed out")), FACTS_TIMEOUT_MS);
    });
    return await Promise.race([gather(snapshot, reason, fallback), timeout]);
  } catch (err) {
    logger.warn(
      { taskId: run.ref.id, reason, err: err instanceof Error ? err.message : String(err) },
      "Resume: could not read the MR's target branch or failed jobs; using the fallback",
    );
    return fallback;
  } finally {
    if (timer) clearTimeout(timer);
  }
}

async function gather(
  snapshot: WorldSnapshot,
  reason: "ci_failure" | "conflicts",
  fallback: ResumeFacts,
): Promise<ResumeFacts> {
  const run = snapshot.run;
  if (run.kind !== "repo" || !run.status.prUrl) return fallback;
  const pr = parsePrUrl(run.status.prUrl);
  if (!pr) return fallback;

  // The task's own creator and workspace context, as the watcher reads the MR.
  const [row] = await db
    .select({
      createdBy: tasks.createdBy,
      workspaceId: tasks.workspaceId,
    })
    .from(tasks)
    .where(eq(tasks.id, run.ref.id));
  const { platform, ri, token } = await getGitPlatformForRepo(run.spec.repoUrl, {
    userId: row?.createdBy ?? undefined,
    workspaceId: row?.workspaceId ?? run.spec.workspaceId,
  });
  const mr = await platform.getPullRequest(ri, pr.prNumber);
  const facts: ResumeFacts = { targetBranch: mr.baseBranch || fallback.targetBranch };

  const headSha = mr.headSha || snapshot.pr?.headSha;
  const workspaceId = row?.workspaceId ?? run.spec.workspaceId;
  const jenkinsJob =
    reason === "ci_failure" && headSha && jenkinsFailureLogsEnabled()
      ? await repoJenkinsJob(run.spec.repoUrl, workspaceId)
      : null;
  if (jenkinsJob && headSha) {
    const access = await jenkinsAccess(workspaceId);
    const jenkins = access
      ? await fetchJenkinsFailedBuilds(jenkinsJob, headSha, access).catch((err) => {
          logger.warn(
            { taskId: run.ref.id, err: err instanceof Error ? err.message : String(err) },
            "Resume: could not read the failed Jenkins builds",
          );
          return null;
        })
      : null;
    // Jenkins failed: that's what to fix. Otherwise the platform's own CI failed.
    if (jenkins) {
      facts.ciFailure = jenkins;
      return facts;
    }
  }
  if (reason === "ci_failure" && headSha && ciFailureLogsEnabled(ri.platform)) {
    // Without the logs the resume still gets the target branch.
    const read = fetchFailedJobLogs(ri, token, headSha, { mrIid: pr.prNumber });
    facts.ciFailure = await read.catch((err) => {
      logger.warn(
        { taskId: run.ref.id, err: err instanceof Error ? err.message : String(err) },
        "Resume: could not read the failed jobs' logs",
      );
      return null;
    });
  }
  return facts;
}
