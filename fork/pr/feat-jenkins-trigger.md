feat(triggers): Jenkins builds start work

## What

Jenkins builds can start Optio work. `jenkins` becomes the fifteenth trigger type and attaches to any target: a Repo Task, a Job, a Local automation, or a persistent agent's turn.

A follow-up pull request (Jenkins builds as a repo's CI checks) is stacked on this one.

## How it works

- **Self-secret receiver**, like Datadog and Alertmanager: Jenkins can't sign, so each trigger has its own URL `POST /api/hooks/jenkins/<trigger id>` and shared secret (`X-Optio-Secret`, `Authorization: Bearer`, or basic auth), minted on create and shown once.
- **Two payload shapes**: the Notification plugin's JSON (`{ name, url, build: { number, phase, status, full_url, scm, parameters, log } }`) and a flat shape a Jenkinsfile `post` step sends (snippet in `docs/jenkins.md`, secret written to a header file so it never reaches `ps` or the build log).
- **Filters**: `events` (`started` / `succeeded` / `failed` / `unstable` / `aborted` / `not_built`; empty = any _finished_ build, never a start), `jobs` (full or short name, `*` globs like `platform/api/*`), `branches`.
- **Prompt params**: `job`, `jobName`, `number`, `url`, `status`, `branch`, `commit`, `repoUrl`, `changeId`, `durationMs`, `parameters`, `log` (≤ 8 000 chars, secrets masked), `payload`.
- **One run per build result**: the plugin reports COMPLETED and FINALIZED for one build; the receiver keys the delivery by `job#number:result` (an `Idempotency-Key` header still wins), so the durable delivery starts one run.
- Job names stay Jenkins' own (`JOB_NAME`): a multibranch branch `feature/x` is `platform/api/feature%2Fx`.

## Where

| Area            | Change                                                                                                                                                                                                                                              |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `@optio/shared` | `jenkins` in the trigger / event / self-secret / wake-source lists; `JenkinsEvent`, `JenkinsTriggerConfig`, `JENKINS_EVENT_KINDS`                                                                                                                   |
| API             | `normalizeJenkinsEvent` / `matchJenkinsTrigger` / `jenkinsEventParams` / `jenkinsDeliveryKey` + `firingFor` branch; receiver in `routes/hooks.ts` (receivers may now derive a delivery key); validation, schema docs, config-as-code `when.jenkins` |
| Web             | Work form: Jenkins When with kinds, `jobs` / `branches`, setup note, example prompt; secret hand-off copy; trigger summaries; generic build glyph (not the Jenkins logo)                                                                            |
| Native          | Regenerated `SharedTypes.swift` / `SharedTypes.kt` only. The iOS and Android forms don't offer Jenkins yet; native code switches only on its own enums, so nothing else changes                                                                     |
| Docs            | New `docs/jenkins.md`; trigger counts and lists in `AGENTS.md`, `README.md`, `docs/tasks.md`, `docs/optio-local.md`, `docs/feature-lists.md`; CHANGELOG                                                                                             |

No migration: trigger types aren't constrained in the database.

## Tests

- `event-trigger-jenkins.test.ts` (14): both payload shapes, job names from URLs, phase → kind, filters and globs, masked log, params, delivery key, firing.
- `hooks-jenkins.test.ts` (5): secret checks, matched:false, one key for COMPLETED + FINALIZED, `Idempotency-Key` precedence, 404s.
- Updated pinned lists/counts (`WHEN_TYPES`, features 14 → 15).

Run locally: typecheck (api, web, shared, cli), eslint on changed files, knip, prettier, unit suites — shared 1043, api 4318 (one pre-existing failure in `outbound-url.test.ts` that also fails on clean upstream in this sandbox: it needs real loopback/DNS), web 1119.

**Not run here** (no Docker / Playwright / Android SDK / Xcode in this environment): integration, pipeline e2e, web e2e, native builds. Worth a `pnpm check:push` locally before merging.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_018eB9e7utYdRjcHXZ7PEB3d
