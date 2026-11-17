fix(web): drop a dead session cookie and send the page to sign-in

## Summary

When the API stops accepting a session, the browser keeps its session cookie for the cookie's 30 days, and the person stays signed out until they clear their browser data.

A session ends on the server when it expires (30 days), goes unused for 7 days (or the deployment's idle timeout), is revoked on sign-out, or is revoked when an admin changes the person's role or removes them from a workspace (`updateMemberRole` / `removeMember`). The web app then:

- lets every page load, because `middleware.ts` only checks that an `optio_session` cookie exists;
- treats the 401 from `/api/auth/me` as "loaded, nobody signed in" (`useCurrentUserStore.load()`), so the page shows no user menu and does not go to `/login`;
- never clears the cookie on sign-out either: the API's logout answers with a `Set-Cookie` that deletes it, but the BFF proxy (`app/api/[...path]/route.ts`) does not forward the API's `Set-Cookie`.

## Changes

- `apps/web/src/app/api/[...path]/route.ts`: the proxy deletes the session cookie itself (same attributes it was set with, `Max-Age=0`) on `POST /api/auth/logout`, and when the API answers `401 "Invalid or expired session"` to a request that carried the cookie. It reads the body only for a 401 on a cookie-carrying request, to tell a dead session from other 401s such as a wrong LDAP password, and passes the same body on.
- `apps/web/src/lib/api-client.ts`: a request that comes back `401 "Invalid or expired session"` sends the page to `/login?redirect=<path>`, except from the pages that work signed out (the middleware's public paths).
- `apps/web/src/lib/auth-cookies.ts`: the error strings and the rule for when the cookie is dead.

## Testing

TESTING

## Related

`/login` does not act on its `redirect` parameter yet (the middleware already sets it), so after signing in again the person lands on `/`.
