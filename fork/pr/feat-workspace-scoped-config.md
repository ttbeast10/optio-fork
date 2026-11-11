feat(scope): resolve configuration inside the workspace first

## Summary

A configuration row with no workspace (a `global` secret, a legacy connection, MCP server, skill or installed skill, the agent-settings row) is read by every workspace on the deployment. On a deployment with more than one workspace that means a second workspace's agents run with the first one's organization secrets and connections, and a ticket provider syncs issues into repos of workspaces it was never set up for.

With this change a workspace's configuration resolves inside the workspace first, and a row with no workspace is the deployment's own: the founding workspace reads it, any other only once a deployment admin shares it as a **deployment default**. Upgrading changes nothing for an existing deployment: the migration marks every existing deployment row as shared. New deployment rows start unshared.

## Changes

- **One rule** (`services/deployment-defaults.ts`, `workspaceOrDeploymentDefault`): lists and pod lookups for secrets, connections, MCP servers, skills, installed skills and agent settings read the workspace's rows, plus the deployment's when the workspace is the founding one or the row is a deployment default (`deployment_default` column).
- **Secrets** get a `workspace` scope: a workspace's own organization secret, read before the deployment's (`retrieveSecretWithFallback`), counted in the setup secrets, and where organization agent credentials are stored.
- **Ticket providers** get a `workspace_id`: their routes are workspace-admin scoped, the sweep matches a provider only against its own workspace's repos, and the Issues page and work-link statuses ask the workspace's own providers.
- **Deployment rows** (`routes/deployment-rows.ts`): only deployment authority changes one (403 otherwise). `PATCH` takes `deploymentDefault`; `PUT /api/secrets/:name/deployment-default` shares a secret. A connection is assigned only to its own workspace's repos, and the assignment resolver finds the workspace's repo by URL.
- **Migration** `1795300000_workspace_scoped_config`: adds the columns and shares every existing deployment row.
- Shared types (`connection.ts`, `mcp.ts`) with the regenerated Swift and Kotlin models. Docs: `docs/scope.md` ("The deployment's own"), `docs/connections.md`, `docs/model-providers.md`, `AGENTS.md`, `CHANGELOG.md`.

## Testing

- New `apps/api/src/services/workspace-scoped-config.int.test.ts` (real Postgres): a second workspace does not read the first one's organization secrets, connections, MCP servers or skills until they are shared; the founding workspace keeps reading the deployment's; a workspace's own secret wins over the deployment's.
- New `apps/api/src/db/workspace-scoped-config-migration.int.test.ts`: the migration shares the rows that existed before it.
- `routes/ticket-providers.int.test.ts` covers the per-workspace providers; the secret, connection, MCP server, skill and agent-credential suites cover the new scope.

- [ ] `pnpm check:push` passes (every check CI runs, sized to the change; `pnpm lint` and `pnpm knip` are the quick local checks).

## Related

Adds a migration at the next journal index. If another pull request with a migration is merged first, I will rebase and renumber this one.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
