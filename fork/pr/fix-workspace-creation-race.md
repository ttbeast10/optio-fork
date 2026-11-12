fix(api): create one Default workspace when first requests race

## Summary

A new user's first sign-in can create two or three workspaces, all named `Default` (`ws-<id8>`, `ws-<id8>-<hex>`), milliseconds apart.

`ensureUserHasWorkspace()` reads the user's default, then their memberships, then creates a workspace, with no lock. On first load the web app sends several authenticated requests at once (`/api/auth/me`, `/api/workspaces`, `/api/setup/status`, …). Each one goes through the auth hook's fallback (`plugins/auth.ts`), and `completeSignIn()`'s bootstrap claim may call the same function at the same time. Every caller sees "no workspace" before any insert commits. The UNIQUE `workspaces.slug` doesn't prevent the duplicate. Either the losing caller renames its workspace with the random suffix, or, when two callers both saw the base slug free, its insert fails with `workspaces_slug_unique` and that request returns a 500.

## Changes

- `apps/api/src/services/workspace-service.ts`
  - The check-and-create runs in one transaction under a per-user advisory lock, `pg_advisory_xact_lock(hashtextextended(userId, 0))`, and re-checks inside the lock. Waiting callers get the workspace the first caller made.
  - Looking up a workspace the user already has (saved default, or oldest membership) still happens first, without the lock, so the normal path is unchanged.
  - The workspace-creation policy (`mayGetOwnWorkspace`) is read before the lock is taken. It queries on its own pool connections. If it ran inside the lock, enough waiting callers could hold every pool connection, and the lock holder would never get one.
  - `createWorkspace()` and `getUserRole()` take an optional executor (default `db`), so the workspace, membership and default-workspace writes all run in the transaction. No other caller changes.
- No schema change and no new dependency. The `-<hex>` slug fallback stays, because two users can share the first 8 characters of their id.

## Testing

New `apps/api/src/services/workspace-service.int.test.ts` runs against real Postgres 16:

- Five concurrent calls for a new user create exactly one workspace, and every call returns its id (three users in a row). **Fails on `main`: three workspaces created.**
- `completeSignIn()`'s bootstrap racing four request-time calls creates one workspace, which becomes the organization's. **Fails on `main`: a `workspaces_slug_unique` violation.**
- Single calls: a new user gets one `Default` workspace they administer, saved as their default. An existing membership is returned and saved as the default. A stale default is replaced. An unknown user gets null.

The new tests passed five runs in a row, and the existing sign-in integration tests and the workspace and auth unit tests pass. Lint, knip, typecheck, unit, integration, API e2e (38 files) and the browser e2e suite (155 tests) all pass.

- [ ] `pnpm check:push` passes (every check CI runs, sized to the change; `pnpm lint` and `pnpm knip` are the quick local checks). Not ticked: run as one command on my machine, the parallel API e2e and browser suites timed out under load. Each of them passes when run by itself.

## Related

Existing deployments may already contain duplicate `Default` workspaces. This PR doesn't remove them; a manual cleanup can be done separately.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_018eB9e7utYdRjcHXZ7PEB3d
