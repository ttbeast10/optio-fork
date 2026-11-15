import { describe, expect, it } from "vitest";
import { SESSION_ENDED_ERROR, sessionCookieIsDead } from "./auth-cookies";

describe("when the web drops the session cookie", () => {
  it("drops it once the API refuses the session", () => {
    expect(sessionCookieIsDead("GET", "/api/tasks", 401, SESSION_ENDED_ERROR)).toBe(true);
  });

  it("drops it on sign-out, whatever the API answered", () => {
    expect(sessionCookieIsDead("POST", "/api/auth/logout", 200, undefined)).toBe(true);
    expect(sessionCookieIsDead("POST", "/api/auth/logout", 500, undefined)).toBe(true);
  });

  it("keeps it on any other refusal", () => {
    expect(
      sessionCookieIsDead("POST", "/api/auth/ldap/login", 401, "Wrong username or password"),
    ).toBe(false);
    expect(sessionCookieIsDead("GET", "/api/tasks", 403, "Requires admin role")).toBe(false);
    expect(sessionCookieIsDead("GET", "/api/tasks", 200, undefined)).toBe(false);
    expect(sessionCookieIsDead("GET", "/api/auth/logout", 200, undefined)).toBe(false);
  });
});
