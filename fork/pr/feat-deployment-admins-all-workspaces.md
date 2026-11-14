feat(auth): let deployment admins administer every workspace

## Summary

A deployment admin can sign in to an organization's Optio and still be locked out of most of it: they administer only the workspaces they are a member of. On a deployment where people create their own workspaces, nobody can look into a workspace whose only admin has left or is away.

This adds one switch, off by default. When it is on, every deployment admin is an admin of every workspace, member or not. The grant is applied when a role is checked; nothing is stored as a membership, so turning the switch off takes it away again. It is visible to the workspace (its members list shows the deployment admins) and logged (a workspace's activity records each day a deployment admin used it).

## Changes

- **The grant** (`services/deployment-admin-grant.ts`, `workspace-service.ts`): `getUserRole` and `getWorkspaceAccess` apply it on every check, so the auth plugin, `requireRole`, the WebSockets, the controller MCP and the workspace routes all follow it. `getMembershipRole` is the plain membership, used where the question is another person's standing in a workspace, so a workspace admin can't delete a deployment admin's private secrets.
- **The switch**: deployment setting `deployment-admins.all-workspaces`, at Settings → Access → **Admins of every workspace** (On / Off / Follow the deployment), over `OPTIO_DEPLOYMENT_ADMINS_ALL_WORKSPACES` / Helm `auth.deploymentAdminsAllWorkspaces`. The card lists the deployment admins it applies to. Changes are logged like every deployment setting.
- **Visible**: `GET /api/workspaces` lists every workspace for a deployment admin, marked `viaDeploymentAdmin`, and the web switcher labels them. `GET /api/workspaces/:id/members` returns `deploymentAdmins` (each with their own membership role there, or null), and Workspace settings → Members lists them, marked "Deployment admin".
- **Logged**: the first request each day that a deployment admin makes in a workspace through the grant writes `workspace.deployment_admin_access` to that workspace's activity (one entry per person, workspace and UTC day, deduplicated in Redis; `services/deployment-admin-audit.ts`). Removing someone from the deployment admins is now logged (`sign_in.deployment_admin_removed`), like adding.
- Shared types (`packages/shared/src/types/workspace.ts`) with the regenerated Swift and Kotlin models. Docs: `docs/sign-in.md`, `docs/scope.md`, `AGENTS.md`, `SECURITY.md`, `CHANGELOG.md`.
- No schema change.

## Testing

- New `apps/api/src/plugins/deployment-admin-access.int.test.ts` (real Postgres and Redis): with the switch off a deployment admin gets a 403 in a workspace they are not a member of; with it on they administer it; the members list names them; the access entry is written once a day; a workspace admin still cannot touch a deployment admin's private secrets.
- Unit tests for the grant, the settings card, the members section, the workspace switcher, and the changed routes.

- [ ] `pnpm check:push` passes (every check CI runs, sized to the change; `pnpm lint` and `pnpm knip` are the quick local checks).

## Related

Follows the discussion in #743 (deployment admins join any workspace).

This touches `ensureUserHasWorkspace()` / `getUserRole()` in `workspace-service.ts`, the same function as the fix for duplicate Default workspaces on a racing first sign-in (`fix/workspace-creation-race`). The two merge without a conflict but do not compile together: that fix passes its transaction to `getUserRole`, which here takes none and becomes `getMembershipRole` for the plain membership read. Whichever of the two is merged second needs a small follow-up (about twenty lines in `workspace-service.ts`: inside the per-user lock, check the saved default on the transaction). I have that change ready and will rebase the second one onto `main` with it.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
