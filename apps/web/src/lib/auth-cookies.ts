/** HTTPS cookies are host-bound so a sibling subdomain cannot plant a login. */
export function secureAuthCookies(): boolean {
  return process.env.PUBLIC_URL?.startsWith("https://") === true;
}

export function authCookieName(name: "session" | "oauth_verifier"): string {
  return `${secureAuthCookies() ? "__Host-" : ""}optio_${name}`;
}

/**
 * The API's answer to a session token it no longer accepts: expired, idle too
 * long, revoked on sign-out, or ended when an admin changed the person's role
 * (apps/api: plugins/auth.ts, routes/auth.ts).
 */
export const SESSION_ENDED_ERROR = "Invalid or expired session";

/**
 * The API's answers that mean the person is signed out. Only a session the API
 * refused counts: "Authentication required" also comes from per-user routes
 * when sign-in is turned off (OPTIO_AUTH_DISABLED), where there is no sign-in
 * to go to, and a request with no cookie at all is already sent to /login by
 * the middleware.
 */
export const SIGNED_OUT_ERRORS: readonly string[] = [SESSION_ENDED_ERROR];

/**
 * Whether the web should drop the browser's session cookie after the API
 * answered a request that carried it. A cookie the API refuses would otherwise
 * stay for its 30 days: the middleware only checks that a cookie is there, so
 * every page would open signed out with no way back to /login.
 */
export function sessionCookieIsDead(
  method: string,
  path: string,
  status: number,
  error: unknown,
): boolean {
  if (method === "POST" && path === "/api/auth/logout") return true;
  return status === 401 && error === SESSION_ENDED_ERROR;
}

/** Attributes that delete the session cookie (the same ones that set it). */
export function expiredSessionCookie() {
  return {
    path: "/",
    httpOnly: true,
    sameSite: "lax" as const,
    secure: secureAuthCookies(),
    maxAge: 0,
  };
}
