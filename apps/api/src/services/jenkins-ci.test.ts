/**
 * Jenkins as a repo's CI (jenkins-ci.ts): reading a job's builds for a
 * commit, turning them into checks, waiting while Jenkins has no answer,
 * adding them to a platform's checks, and the failed builds' console tails
 * for a CI-fix resume. Jenkins' HTTP answers are stubbed through the
 * outbound guard's `fetchImpl`.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { GitPlatform, RepoIdentifier } from "@optio/shared";
import { setOutboundDefaults } from "../utils/outbound-url.js";

vi.mock("../db/client.js", () => ({ db: {} }));
vi.mock("./secret-service.js", () => ({
  retrieveSecretWithFallback: vi.fn().mockRejectedValue(new Error("Secret not found")),
}));

import {
  JENKINS_PENDING_CHECK,
  buildsForCommit,
  buildsOfTree,
  checkOfBuild,
  fetchJenkinsFailedBuilds,
  jenkinsAccess,
  jenkinsBaseUrl,
  jenkinsChecks,
  withJenkinsChecks,
  type JenkinsAccess,
} from "./jenkins-ci.js";
import { jenkinsJobPath, validJenkinsJob } from "../utils/jenkins-job.js";
import { ciFailurePrompt } from "./resume-prompts.js";

const HEAD = "0123456789abcdef0123456789abcdef01234567";
const OTHER = "fedcba9876543210fedcba9876543210fedcba98";

/** A multibranch job's tree: a PR job that built the merge, a branch job, a stale build. */
const MULTIBRANCH = {
  fullName: "platform/api",
  jobs: [
    {
      fullName: "platform/api/PR-12",
      builds: [
        {
          number: 3,
          url: "https://ci.example.com/job/platform/job/api/job/PR-12/3/",
          result: null,
          building: true,
          actions: [{ lastBuiltRevision: { SHA1: "aaaa" } }, { revision: { pullHash: HEAD } }],
        },
        {
          number: 2,
          url: "https://ci.example.com/job/platform/job/api/job/PR-12/2/",
          result: "FAILURE",
          building: false,
          actions: [{ revision: { pullHash: HEAD } }],
        },
        {
          number: 1,
          url: "https://ci.example.com/job/platform/job/api/job/PR-12/1/",
          result: "SUCCESS",
          building: false,
          actions: [{ revision: { pullHash: OTHER } }],
        },
      ],
    },
    {
      fullName: "platform/api/feature%2Flogin",
      builds: [
        {
          number: 7,
          url: "https://ci.example.com/job/platform/job/api/job/feature%252Flogin/7/",
          result: "UNSTABLE",
          building: false,
          actions: [{}, { lastBuiltRevision: { SHA1: HEAD.toUpperCase() } }],
        },
      ],
    },
    {
      fullName: "platform/api/MR-4-merge",
      builds: [
        {
          number: 1,
          url: "https://ci.example.com/job/platform/job/api/job/MR-4-merge/1/",
          result: "SUCCESS",
          building: false,
          actions: [{ revision: { hash: "bbbb", origin: { hash: HEAD } } }],
        },
      ],
    },
  ],
};

const ACCESS: JenkinsAccess = {
  baseUrl: "https://ci.example.com",
  headers: { Accept: "application/json", Authorization: "Basic b3B0aW86dG9rZW4tc2VjcmV0LTEyMw==" },
  secrets: ["token-secret-123"],
};

const fetchImpl = vi.fn();
let restore: () => void;

beforeEach(() => {
  fetchImpl.mockReset();
  restore = setOutboundDefaults({
    fetchImpl: (url, init) => fetchImpl(url, init),
    resolveHost: async () => [{ address: "93.184.216.34", family: 4 }],
  });
});
afterEach(() => restore());

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

describe("job names", () => {
  it("turns a full name into its URL path, encoding each segment once more", () => {
    expect(jenkinsJobPath("platform/api")).toBe("/job/platform/job/api");
    expect(jenkinsJobPath("/nightly/")).toBe("/job/nightly");
    expect(jenkinsJobPath("platform/api/feature%2Fx")).toBe(
      "/job/platform/job/api/job/feature%252Fx",
    );
  });

  it("refuses names that would leave the job tree", () => {
    for (const bad of ["", "a//b", "../admin", "a/./b", "a?b", "a#b", "a\\b", "a\nb"]) {
      expect(validJenkinsJob(bad)).toBe(false);
    }
  });

  it("reads JENKINS_URL, http(s) only, without a trailing slash", () => {
    expect(jenkinsBaseUrl({ JENKINS_URL: "https://ci.example.com/jenkins/" })).toBe(
      "https://ci.example.com/jenkins",
    );
    expect(jenkinsBaseUrl({})).toBeNull();
    expect(jenkinsBaseUrl({ JENKINS_URL: "file:///etc/passwd" })).toBeNull();
  });
});

describe("builds for a commit", () => {
  const builds = buildsOfTree(MULTIBRANCH, "platform/api");

  it("reads every branch job's builds and the commits each built", () => {
    expect(builds).toHaveLength(5);
    expect(builds[0]).toMatchObject({ job: "platform/api/PR-12", number: 3, building: true });
    expect(builds[0].revisions).toEqual(["aaaa", HEAD]);
  });

  it("keeps each job's newest build of the commit, by SHA1, pullHash or a GitLab MR's head", () => {
    const hits = buildsForCommit(builds, HEAD);
    expect(hits.map((b) => `${b.job}#${b.number}`)).toEqual([
      "platform/api/feature%2Flogin#7",
      "platform/api/MR-4-merge#1",
      "platform/api/PR-12#3",
    ]);
    expect(buildsForCommit(builds, "nope")).toEqual([]);
  });

  it("reads a plain job's own builds", () => {
    const plain = buildsOfTree(
      {
        fullName: "nightly",
        builds: [
          { number: 9, result: "SUCCESS", actions: [{ lastBuiltRevision: { SHA1: HEAD } }] },
        ],
      },
      "nightly",
    );
    expect(buildsForCommit(plain, HEAD).map((b) => b.job)).toEqual(["nightly"]);
  });

  it("maps a build to a check", () => {
    const b = { job: "j", number: 1, url: "", revisions: [], building: false };
    expect(checkOfBuild({ ...b, building: true, result: null })).toEqual({
      name: "Jenkins j",
      status: "in_progress",
      conclusion: null,
    });
    expect(checkOfBuild({ ...b, result: "SUCCESS" }).conclusion).toBe("success");
    expect(checkOfBuild({ ...b, result: "FAILURE" }).conclusion).toBe("failure");
    expect(checkOfBuild({ ...b, result: "UNSTABLE" }).conclusion).toBe("failure");
    expect(checkOfBuild({ ...b, result: "ABORTED" }).conclusion).toBe("cancelled");
    expect(checkOfBuild({ ...b, result: "NOT_BUILT" }).conclusion).toBe("skipped");
    expect(checkOfBuild({ ...b, result: null }).status).toBe("queued");
  });
});

describe("jenkinsChecks", () => {
  it("reads the job's tree under JENKINS_URL with the token and returns its checks", async () => {
    fetchImpl.mockResolvedValue(json(MULTIBRANCH));
    const checks = await jenkinsChecks("platform/api", HEAD, ACCESS);
    expect(checks).toEqual([
      { name: "Jenkins platform/api/feature%2Flogin", status: "completed", conclusion: "failure" },
      { name: "Jenkins platform/api/MR-4-merge", status: "completed", conclusion: "success" },
      { name: "Jenkins platform/api/PR-12", status: "in_progress", conclusion: null },
    ]);
    const [url, init] = fetchImpl.mock.calls[0];
    expect(String(url)).toMatch(
      /^https:\/\/ci\.example\.com\/job\/platform\/job\/api\/api\/json\?tree=/,
    );
    expect(new Headers(init.headers).get("authorization")).toBe(ACCESS.headers.Authorization);
  });

  it("stays pending while Jenkins has no build of the commit or can't be read", async () => {
    fetchImpl.mockResolvedValueOnce(json({ fullName: "platform/api", jobs: [] }));
    expect(await jenkinsChecks("platform/api", HEAD, ACCESS)).toEqual([JENKINS_PENDING_CHECK]);
    fetchImpl.mockResolvedValueOnce(json({ message: "nope" }, 403));
    expect(await jenkinsChecks("platform/api", HEAD, ACCESS)).toEqual([JENKINS_PENDING_CHECK]);
    fetchImpl.mockRejectedValueOnce(new Error("ECONNREFUSED"));
    expect(await jenkinsChecks("platform/api", HEAD, ACCESS)).toEqual([JENKINS_PENDING_CHECK]);
  });
});

describe("withJenkinsChecks", () => {
  it("adds Jenkins' checks to the platform's and leaves every other method the platform's own", async () => {
    fetchImpl.mockResolvedValue(json(MULTIBRANCH));
    class FakePlatform {
      readonly type = "github";
      private label = "own";
      async getCIChecks() {
        return [{ name: this.label, status: "completed" as const, conclusion: "success" as const }];
      }
      async getPullRequest() {
        return { title: this.label };
      }
    }
    const platform = withJenkinsChecks(
      new FakePlatform() as unknown as GitPlatform,
      "platform/api",
      ACCESS,
    );
    const checks = await platform.getCIChecks({} as RepoIdentifier, HEAD);
    expect(checks.map((c) => c.name)).toEqual([
      "own",
      "Jenkins platform/api/feature%2Flogin",
      "Jenkins platform/api/MR-4-merge",
      "Jenkins platform/api/PR-12",
    ]);
    expect(await platform.getPullRequest({} as RepoIdentifier, 1)).toEqual({ title: "own" });
    expect(platform.type).toBe("github");
  });
});

describe("fetchJenkinsFailedBuilds", () => {
  it("reads each failed build's console under JENKINS_URL, masked, as a Jenkins failure", async () => {
    fetchImpl.mockImplementation(async (url: string) => {
      if (url.includes("/api/json")) return json(MULTIBRANCH);
      expect(url).toBe(
        "https://ci.example.com/job/platform/job/api/job/feature%252Flogin/7/consoleText",
      );
      return new Response(
        "Started by user\n+ npm test\nFAIL app.test.ts\nusing token-secret-123\n",
      );
    });
    const failure = (await fetchJenkinsFailedBuilds("platform/api", HEAD, ACCESS))!;
    expect(failure.ci).toBe("jenkins");
    expect(failure.jobs).toHaveLength(1);
    expect(failure.jobs[0]).toMatchObject({
      id: 7,
      name: "platform/api/feature%2Flogin #7 (unstable)",
      webUrl: "https://ci.example.com/job/platform/job/api/job/feature%252Flogin/7/",
    });
    expect(failure.jobs[0].tail).toContain("FAIL app.test.ts");
    expect(failure.jobs[0].tail).not.toContain("token-secret-123");

    const prompt = ciFailurePrompt("PR", failure);
    expect(prompt).toMatch(/^Jenkins builds failed on your PR: /);
    expect(prompt).toContain("FAIL app.test.ts");
    expect(prompt).not.toContain("gh run view");
  });

  it("is null when no build of the commit failed", async () => {
    fetchImpl.mockResolvedValue(json(MULTIBRANCH));
    expect(await fetchJenkinsFailedBuilds("platform/api", OTHER, ACCESS)).toBeNull();
  });
});

describe("jenkinsAccess", () => {
  it("is null without JENKINS_URL, and signs in with the environment's user and token", async () => {
    expect(await jenkinsAccess(null, {})).toBeNull();
    const access = await jenkinsAccess(null, {
      JENKINS_URL: "https://ci.example.com/",
      JENKINS_USER: "optio",
      JENKINS_API_TOKEN: "token-secret-123",
    });
    expect(access).toMatchObject({
      baseUrl: "https://ci.example.com",
      secrets: ["token-secret-123"],
    });
    expect(access!.headers.Authorization).toBe(
      `Basic ${Buffer.from("optio:token-secret-123").toString("base64")}`,
    );
    const anonymous = await jenkinsAccess(null, { JENKINS_URL: "https://ci.example.com" });
    expect(anonymous!.headers.Authorization).toBeUndefined();
  });
});
