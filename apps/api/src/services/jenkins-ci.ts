/**
 * Jenkins as a repository's CI: the builds of the repo's Jenkins job
 * (`repos.jenkins_job`) for a PR's head commit, read from Jenkins' own API
 * and added to the platform's checks, so the PR watcher, the reconciler
 * (auto-merge, review on CI pass, resume on failure), PR reviews and the PR
 * panel treat a Jenkins build like a GitHub check or a GitLab job — and a
 * CI-fix resume gets the failed builds' console tails.
 *
 * Where Jenkins is: `JENKINS_URL`, set by the deployment's operator. A repo
 * only names a job *path* under it, so the token never goes anywhere else;
 * the host must still be allowed outbound (`OPTIO_OUTBOUND_ALLOWED_HOSTS`),
 * like a self-managed GitLab. Who Optio is to Jenkins: `JENKINS_USER` and
 * `JENKINS_API_TOKEN` (an API token, sent as basic auth), from the
 * workspace's or the deployment's secrets, else the environment; none means
 * anonymous reads.
 *
 * Finding the build for a commit: one `api/json?tree=` read of the job
 * returns, for a multibranch pipeline, each branch / PR job's newest builds,
 * or, for a plain job, its own; a build matches when Jenkins recorded the
 * commit it built (the git plugin's `lastBuiltRevision.SHA1`, a branch
 * source's `revision.hash`, or — when it built the merge — a GitHub PR's
 * `revision.pullHash` or a GitLab MR's `revision.origin.hash`). Each job's newest matching build is one check, `Jenkins <job>`.
 *
 * Until Jenkins answers for the commit — no build yet, or Jenkins can't be
 * reached — the repo gets one pending check, `Jenkins`: a repo that names a
 * Jenkins job waits for it, like a required check, rather than merging on
 * the platform's checks alone. A commit Jenkins never builds keeps the PR
 * waiting; clear the repo's job to stop reading Jenkins.
 */
import { eq } from "drizzle-orm";
import { normalizeRepoUrl, type CICheck, type GitPlatform } from "@optio/shared";
import { db } from "../db/client.js";
import { repos } from "../db/schema.js";
import { guardedFetch } from "../utils/outbound-url.js";
import { jenkinsJobPath, validJenkinsJob } from "../utils/jenkins-job.js";
import {
  maskSecrets,
  readTail,
  tailOfLog,
  type FailedJobs,
} from "./git-platform/gitlab-ci-logs.js";
import { retrieveSecretWithFallback } from "./secret-service.js";
import { logger } from "../logger.js";

const TIMEOUT_MS = 10_000;
const LOG_TIMEOUT_MS = 15_000;
const BUILDS_PER_BRANCH = 10;
const BUILDS_OF_JOB = 25;
const LOG_TAIL_LINES = 150;
const LOG_TAIL_BYTES = 256 * 1024;
const MAX_FAILED_BUILDS = 5;

/** The check a repo gets while Jenkins has no answer for the commit. */
export const JENKINS_PENDING_CHECK: CICheck = {
  name: "Jenkins",
  status: "queued",
  conclusion: null,
};

/** Who Optio is to Jenkins, and where Jenkins is. */
export interface JenkinsAccess {
  baseUrl: string;
  headers: Record<string, string>;
  /** Values to mask in anything read back (the token). */
  secrets: string[];
}

/** One build of the job, as the tree read returns it. */
export interface JenkinsBuild {
  /** The job's full name (`platform/api/PR-12`). */
  job: string;
  number: number;
  url: string;
  result: string | null;
  building: boolean;
  /** Commits this build says it built. */
  revisions: string[];
}

/** `JENKINS_URL` without a trailing slash; null when the deployment has no Jenkins. */
export function jenkinsBaseUrl(env: NodeJS.ProcessEnv = process.env): string | null {
  const raw = (env.JENKINS_URL ?? "").trim().replace(/\/+$/, "");
  if (!raw) return null;
  try {
    const url = new URL(raw);
    return url.protocol === "https:" || url.protocol === "http:" ? raw : null;
  } catch {
    return null;
  }
}

/** How Optio reaches the deployment's Jenkins for work in `workspaceId`; null without `JENKINS_URL`. */
export async function jenkinsAccess(
  workspaceId?: string | null,
  env: NodeJS.ProcessEnv = process.env,
): Promise<JenkinsAccess | null> {
  const baseUrl = jenkinsBaseUrl(env);
  if (!baseUrl) return null;
  const secret = async (name: string) =>
    retrieveSecretWithFallback(name, "global", workspaceId).catch(() => env[name] ?? "");
  const [user, token] = await Promise.all([secret("JENKINS_USER"), secret("JENKINS_API_TOKEN")]);
  const headers: Record<string, string> = { Accept: "application/json", "User-Agent": "Optio" };
  if (token) {
    headers.Authorization = `Basic ${Buffer.from(`${user}:${token}`).toString("base64")}`;
  }
  return { baseUrl, headers, secrets: token ? [token] : [] };
}

const BUILD_FIELDS =
  "number,url,result,building,inProgress," +
  "actions[lastBuiltRevision[SHA1],revision[hash,pullHash,origin[hash]]]";

/** The `tree=` that reads a multibranch job's branches' builds and a plain job's own in one call. */
const JENKINS_TREE =
  `fullName,builds[${BUILD_FIELDS}]{0,${BUILDS_OF_JOB}},` +
  `jobs[fullName,builds[${BUILD_FIELDS}]{0,${BUILDS_PER_BRANCH}}]`;

type Obj = Record<string, unknown>;
const obj = (v: unknown): Obj => (v && typeof v === "object" ? (v as Obj) : {});
const arr = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);
const str = (v: unknown): string => (typeof v === "string" ? v : "");

function buildOf(job: string, raw: unknown): JenkinsBuild | null {
  const b = obj(raw);
  if (typeof b.number !== "number") return null;
  const revisions = new Set<string>();
  for (const a of arr(b.actions)) {
    const action = obj(a);
    const sha1 = str(obj(action.lastBuiltRevision).SHA1);
    if (sha1) revisions.add(sha1.toLowerCase());
    const rev = obj(action.revision);
    // GitHub PR builds: `pullHash` is the head; GitLab MR builds: `origin.hash`.
    for (const v of [str(rev.hash), str(rev.pullHash), str(obj(rev.origin).hash)]) {
      if (v) revisions.add(v.toLowerCase());
    }
  }
  return {
    job,
    number: b.number,
    url: str(b.url),
    result: str(b.result) || null,
    building: b.building === true || b.inProgress === true,
    revisions: [...revisions],
  };
}

/** Every build in a tree read, whichever shape the job has. */
export function buildsOfTree(tree: unknown, job: string): JenkinsBuild[] {
  const t = obj(tree);
  const own = str(t.fullName) || job;
  const out: JenkinsBuild[] = [];
  for (const b of arr(t.builds)) {
    const build = buildOf(own, b);
    if (build) out.push(build);
  }
  for (const child of arr(t.jobs)) {
    const c = obj(child);
    const name = str(c.fullName);
    if (!name) continue;
    for (const b of arr(c.builds)) {
      const build = buildOf(name, b);
      if (build) out.push(build);
    }
  }
  return out;
}

/** Each job's newest build of `sha` (a short SHA in Jenkins matches the full one). */
export function buildsForCommit(builds: JenkinsBuild[], sha: string): JenkinsBuild[] {
  const want = sha.trim().toLowerCase();
  if (!want) return [];
  const newest = new Map<string, JenkinsBuild>();
  for (const b of builds) {
    const built = b.revisions.some((r) => r === want || (r.length >= 7 && want.startsWith(r)));
    if (!built) continue;
    const seen = newest.get(b.job);
    if (!seen || b.number > seen.number) newest.set(b.job, b);
  }
  return [...newest.values()].sort((a, b) => a.job.localeCompare(b.job));
}

/** A build as a CI check: a failed or unstable build fails, an aborted one is cancelled. */
export function checkOfBuild(b: JenkinsBuild): CICheck {
  const name = `Jenkins ${b.job}`;
  if (b.building) return { name, status: "in_progress", conclusion: null };
  switch (b.result) {
    case "SUCCESS":
      return { name, status: "completed", conclusion: "success" };
    case "FAILURE":
    case "UNSTABLE":
      return { name, status: "completed", conclusion: "failure" };
    case "ABORTED":
      return { name, status: "completed", conclusion: "cancelled" };
    case "NOT_BUILT":
      return { name, status: "completed", conclusion: "skipped" };
    default:
      // Not building and no result yet: just scheduled.
      return { name, status: "queued", conclusion: null };
  }
}

async function readTree(access: JenkinsAccess, job: string): Promise<JenkinsBuild[]> {
  const path = jenkinsJobPath(job);
  if (!path) throw new Error(`Not a Jenkins job name: ${job}`);
  const res = await guardedFetch(
    `${access.baseUrl}${path}/api/json?tree=${encodeURIComponent(JENKINS_TREE)}`,
    { headers: access.headers, signal: AbortSignal.timeout(TIMEOUT_MS), redirect: "error" },
  );
  if (!res.ok) throw new Error(`Jenkins API error ${res.status} reading ${job}`);
  return buildsOfTree(await res.json(), job);
}

/** The commit's Jenkins checks; the pending check when there are none yet or Jenkins can't be read. */
export async function jenkinsChecks(
  job: string,
  sha: string,
  access: JenkinsAccess,
): Promise<CICheck[]> {
  try {
    const builds = buildsForCommit(await readTree(access, job), sha);
    return builds.length > 0 ? builds.map(checkOfBuild) : [JENKINS_PENDING_CHECK];
  } catch (err) {
    logger.warn(
      { job, err: err instanceof Error ? err.message : String(err) },
      "Jenkins: could not read the job's builds; its check stays pending",
    );
    return [JENKINS_PENDING_CHECK];
  }
}

/**
 * `platform`, with the commit's Jenkins builds added to its checks. Every
 * other method is the platform's own.
 */
export function withJenkinsChecks(
  platform: GitPlatform,
  job: string,
  access: JenkinsAccess,
): GitPlatform {
  const getCIChecks: GitPlatform["getCIChecks"] = async (ri, sha) => {
    const [own, jenkins] = await Promise.all([
      platform.getCIChecks(ri, sha),
      jenkinsChecks(job, sha, access),
    ]);
    return [...own, ...jenkins];
  };
  return new Proxy(platform, {
    get(target, prop) {
      if (prop === "getCIChecks") return getCIChecks;
      const value = Reflect.get(target, prop, target);
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
}

/**
 * The commit's failed (and unstable) Jenkins builds with the end of each
 * console log, masked, in the shape a CI-fix resume prompt takes (one
 * "job" per build); null when none failed. Logs are read under
 * `JENKINS_URL` whatever URL Jenkins reports for the build.
 */
export async function fetchJenkinsFailedBuilds(
  job: string,
  sha: string,
  access: JenkinsAccess,
  opts: { maxBuilds?: number; tailLines?: number } = {},
): Promise<FailedJobs | null> {
  const maxBuilds = opts.maxBuilds ?? MAX_FAILED_BUILDS;
  const failed = buildsForCommit(await readTree(access, job), sha).filter(
    (b) => !b.building && (b.result === "FAILURE" || b.result === "UNSTABLE"),
  );
  if (failed.length === 0) return null;
  const jobs = await Promise.all(
    failed.slice(0, maxBuilds).map(async (b) => {
      let tail = "";
      const path = jenkinsJobPath(b.job);
      if (path) {
        try {
          const res = await guardedFetch(`${access.baseUrl}${path}/${b.number}/consoleText`, {
            headers: { ...access.headers, Accept: "text/plain" },
            signal: AbortSignal.timeout(LOG_TIMEOUT_MS),
            redirect: "error",
          });
          if (res.ok) {
            tail = tailOfLog(
              await readTail(res, LOG_TAIL_BYTES),
              opts.tailLines ?? LOG_TAIL_LINES,
              access.secrets,
            );
          }
        } catch {
          // The prompt says the log couldn't be read.
        }
      }
      return {
        id: b.number,
        name: `${b.job} #${b.number}${b.result === "UNSTABLE" ? " (unstable)" : ""}`,
        stage: "",
        webUrl: b.url ? maskSecrets(b.url, access.secrets) : undefined,
        tail,
      };
    }),
  );
  return {
    ci: "jenkins",
    pipelineId: failed[0].number,
    jobs,
    more: failed.slice(maxBuilds).map((b) => ({ name: `${b.job} #${b.number}`, stage: "" })),
  };
}

/**
 * The Jenkins job a registered repo names, when the deployment has a
 * Jenkins: the workspace's row for the URL, else any row for it (an
 * unscoped caller reading a status). Null otherwise.
 */
export async function repoJenkinsJob(
  repoUrl: string,
  workspaceId?: string | null,
): Promise<string | null> {
  if (!jenkinsBaseUrl()) return null;
  try {
    const rows = await db
      .select({ workspaceId: repos.workspaceId, jenkinsJob: repos.jenkinsJob })
      .from(repos)
      .where(eq(repos.repoUrl, normalizeRepoUrl(repoUrl)));
    const named = rows.filter((r) => r.jenkinsJob && validJenkinsJob(r.jenkinsJob));
    const row = named.find((r) => r.workspaceId === (workspaceId ?? null)) ?? named[0];
    return row?.jenkinsJob?.trim() ?? null;
  } catch {
    return null;
  }
}

/** `platform` with the repo's Jenkins checks added when it names a job; as is otherwise. */
export async function withRepoJenkins(
  platform: GitPlatform,
  repoUrl: string,
  workspaceId?: string | null,
): Promise<GitPlatform> {
  const job = await repoJenkinsJob(repoUrl, workspaceId);
  if (!job) return platform;
  const access = await jenkinsAccess(workspaceId);
  return access ? withJenkinsChecks(platform, job, access) : platform;
}
