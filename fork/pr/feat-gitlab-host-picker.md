feat(repos): pick between GitLab servers when adding a repository

## Summary

With more than one GitLab server set up, **Repos → Add Repository → GitLab** now shows a button per server; clicking one lists that server's projects. Before, the picker listed only the first host it found, so projects on a second server could only be added by pasting a URL.

## Changes

**API** (`routes/repos.ts`)

- `GET /api/repos/browse` returns `hosts` — every host the platform can be listed on, the default first — and takes `host` to list one of them.
- GitLab hosts, in order: the saved `GITLAB_HOST` secret, the self-managed hosts in `GITLAB_HOSTS`, the hosts of GitLab repos the workspace already has, then `gitlab.com` when `GITLAB_HOSTS` names it (or when there is nothing else). The first is what was listed before, so the default is unchanged.
- `host` is only ever matched against that list (case-insensitive). Anything else gets an empty list and an explanation, without resolving a token — credentials still go only to hosts the workspace is set up with, and the existing `GITLAB_HOSTS` trust check still applies to the chosen host.
- The token is looked up for the chosen host (`GITLAB_TOKEN_<HOST>`, else `GITLAB_TOKEN`), as before.

**Web** (`components/gitlab-repo-browser.tsx`)

- A segmented control of the servers above the search box when there is more than one; nothing changes with a single host.
- The search placeholder names the server being searched.

**Docs**: `docs/gitlab-repositories.md`, CHANGELOG.

## Testing

- `repos-browse.test.ts`: the host list and its order, listing an asked-for host with that host's token, refusing a host that isn't the workspace's without a token lookup or a request.
- `gitlab-repo-browser.test.tsx`: the server buttons, switching, no control with one host.
- `e2e/gitlab-hosts.spec.ts` (Playwright, real web + API stack, the two GitLab servers stubbed at the browser): switch server, pick a project, the URL is on the chosen server.

Run locally and passing: lint, knip, typecheck, prettier, API unit tests (`--changed`), API integration (`--changed`), the full API e2e tier (38 files) and the full browser suite.

- [ ] `pnpm check:push` passes (every check CI runs, sized to the change; `pnpm lint` and `pnpm knip` are the quick local checks). Not ticked: run as one command on my machine, the parallel API e2e suite timed out under load (it passes by itself), and one web unit file this change does not touch, `optio-chat-panel.test.tsx`, hits its 5 s test timeout there. It does the same on unmodified `main` on that machine and passes when run alone.

## Related

None.

## Screenshots

Two servers, the second one picked: a segmented control (`gitlab.corp.example` | `git.lab.example`) above the project search, listing the picked server's projects.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_018eB9e7utYdRjcHXZ7PEB3d
