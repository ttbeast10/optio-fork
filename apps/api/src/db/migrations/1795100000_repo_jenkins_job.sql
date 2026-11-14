-- The Jenkins job that builds a repository's branches and pull requests
-- (`platform/api`, a multibranch pipeline or a single job), read as the PR's
-- CI checks when the deployment has a Jenkins (JENKINS_URL, docs/jenkins.md).
-- Null: Jenkins doesn't build this repo, or Optio doesn't read it.
ALTER TABLE "repos" ADD COLUMN IF NOT EXISTS "jenkins_job" text;
