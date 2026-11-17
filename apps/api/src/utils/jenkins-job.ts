/** Jenkins job names as URL paths: pure, for the repo setting's schema and jenkins-ci.ts. */

/**
 * A job's full name (`platform/api`, `platform/api/feature%2Fx`) as its URL
 * path (`/job/platform/job/api`, `/job/platform/job/api/job/feature%252Fx`);
 * null for a name that isn't one (empty segments, `.` / `..`, control
 * characters), so a repo setting can only point inside `JENKINS_URL`.
 */
export function jenkinsJobPath(job: string): string | null {
  const segments = job
    .trim()
    .replace(/^\/+|\/+$/g, "")
    .split("/");
  if (segments.length === 0 || segments.length > 20) return null;
  for (const s of segments) {
    if (!s || s === "." || s === ".." || /[\u0000-\u001f\u007f?#\\]/.test(s)) return null;
  }
  return segments.map((s) => `/job/${encodeURIComponent(s)}`).join("");
}

/** A job name a repo may save: what `jenkinsJobPath` accepts, as typed (trimmed). */
export function validJenkinsJob(job: string): boolean {
  return jenkinsJobPath(job) !== null;
}
