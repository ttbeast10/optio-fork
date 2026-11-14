feat(scope): resolve configuration inside the workspace first

## Summary

A configuration row with no workspace (a `global` secret, a legacy connection, MCP server, skill or installed skill, the agent-settings row) is read by every workspace on the deployment. On a deployment with more than one workspace that means a second workspace's agents run with the first one's organization secrets and connections, and a ticket provider syncs issues into repos of workspaces it was never set up for.

With this change a workspace's configuration resolves inside the workspace first, and a row with no workspace is the deployment's own: the founding workspace reads it, any other only once a deployment admin shares it as a **deployment default**. Upgrading changes nothing for an existing deployment: the migration marks every existing deployment row as shared. New deployment rows start unshared.

This branch also carries **per-workspace GitLab**, which follows the same rule. Each workspace adds its own GitLab servers and tokens under Workspace Settings → GitLab, and server-side git calls resolve credentials in the workspace they act for. It also keeps **events inside their workspace**: notification webhooks and the Slack fallback. And it adds an **in-app control** for sharing deployment rows.

## Changes

- **One rule** (`services/deployment-defaults.ts`, `workspaceOrDeploymentDefault`): lists and pod lookups for secrets, connections, MCP servers, skills, installed skills and agent settings read the workspace's rows, plus the deployment's when the workspace is the founding one or the row is a deployment default (`deployment_default` column).
- **Secrets** get a `workspace` scope: a workspace's own organization secret, read before the deployment's (`retrieveSecretWithFallback`), counted in the setup secrets, and where organization agent credentials are stored.
- **Ticket providers** get a `workspace_id`: their routes are workspace-admin scoped, the sweep matches a provider only against its own workspace's repos, and the Issues page and work-link statuses ask the workspace's own providers.
- **Deployment rows** (`routes/deployment-rows.ts`): only deployment authority changes one (403 otherwise). `PATCH` takes `deploymentDefault`; `PUT /api/secrets/:name/deployment-default` shares a secret. A connection is assigned only to its own workspace's repos, and the assignment resolver finds the workspace's repo by URL.
- **Migration** `1795300000_workspace_scoped_config`: adds the columns and shares every existing deployment row.
- **GitLab per workspace** (`services/workspace-gitlab-service.ts`, `routes/workspace-gitlab.ts`, `docs/workspace-gitlab.md`):
  - New table `workspace_gitlab_servers`, with migration `1795300100_workspace_gitlab_servers`. Each token is a `workspace`-scope secret, `GITLAB_TOKEN_<HOST>`.
  - `GET /api/workspace/gitlab` is open to members; `POST`, `PATCH` and `DELETE /api/workspace/gitlab/servers[/:id]` are admin-only. A token is checked against `/api/v4/user` before it is stored, and a host must be `gitlab.com` or listed in `GITLAB_HOSTS`.
  - Token order: the person's own, then the workspace's own, then the deployment's, under the deployment-default rule. Tokens set only in the API's environment serve the founding workspace alone.
  - Every server-side `getGitPlatformForRepo` call now passes the workspace it acts for: the PR watcher, reconciler, PR reviews, PR and repo detection, issue closing, issues routes and controller PR status. Pods and the signed credential helper resolve tokens the same way.
  - The helper never trusts a `GITLAB_HOST` that a workspace saved itself.
  - `GITLAB_TOKEN_<HOST>` secrets are kept out of repo pods' setup env.
  - Web: a Workspace Settings → GitLab card. The setup wizard saves the workspace's own server, and Add repository reads it.
- **Events stay in their workspace**:
  - `getWebhooksForEvent(event, workspaceId)`: a notification webhook gets its own workspace's events. A webhook with no workspace gets only the founding workspace's events and events with no workspace.
  - `SLACK_WEBHOOK_URL` resolves per workspace.
- **Sharing in the app** (`components/settings/deployment-share.tsx`):
  - Every deployment row in Settings (Deployment secrets, MCP servers, custom and marketplace skills) and on the Connections page shows "Deployment · every workspace" or "Deployment · founding workspace". A deployment admin clicks the tag to share or stop sharing.
  - Catalog entries carry `deployment` and `deploymentDefault`. `UpdateConnectionInput` takes `deploymentDefault`, with the Swift and Kotlin models regenerated.
- Shared types (`connection.ts`, `mcp.ts`) with the regenerated Swift and Kotlin models. Docs: `docs/scope.md` ("The deployment's own"), `docs/connections.md`, `docs/model-providers.md`, `AGENTS.md`, `CHANGELOG.md`.

## Testing

- New `apps/api/src/services/workspace-scoped-config.int.test.ts` (real Postgres): a second workspace does not read the first one's organization secrets, connections, MCP servers or skills until they are shared; the founding workspace keeps reading the deployment's; a workspace's own secret wins over the deployment's.
- New `apps/api/src/db/workspace-scoped-config-migration.int.test.ts`: the migration shares the rows that existed before it.
- `routes/ticket-providers.int.test.ts` covers the per-workspace providers; the secret, connection, MCP server, skill and agent-credential suites cover the new scope.

- New for GitLab and events:
  - `workspace-gitlab-service.int.test.ts`: sealed, AAD-bound tokens; unlisted hosts and bad tokens refused; each workspace gets its own token; deployment sharing; a workspace's own `GITLAB_HOST` is never trusted.
  - `webhook-scope.int.test.ts`: webhooks get only their own workspace's events.
  - Deployment flags in `connection-catalog.int.test.ts`.
  - Unit tests for host parsing, token precedence, the credential helper, routes, and the web card, share tag and setup wizard.
- Run locally in a sandbox:
  - API unit: 4333 passed. One failure, `utils/outbound-url.test.ts`, fails the same way on clean upstream there because it needs real loopback/DNS.
  - API integration: 780/780. API e2e: 164/164.
  - Web unit: 1134/1134. Shared: 1043/1043.
  - Web e2e, Chromium only: 144 passed, plus the 2 Connections specs after the fix in this branch. The Firefox project did not run because Firefox was not installed. The sandbox's Chromium build was aliased to the one Playwright expects.
  - Lint, knip, prettier, typecheck.
- [ ] `pnpm check:push` passes (every check CI runs, sized to the change; `pnpm lint` and `pnpm knip` are the quick local checks). Not run to completion: the Firefox browser project and the network-dependent test above couldn't run in the sandbox.

## Related

Adds two migrations (`1795300000_workspace_scoped_config`, `1795300100_workspace_gitlab_servers`) at the next journal indexes. If another pull request with a migration is merged first, I will rebase and renumber this one.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
