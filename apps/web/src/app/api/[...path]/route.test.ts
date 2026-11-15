// @vitest-environment node
import { afterEach, describe, expect, it, vi } from "vitest";
import { NextRequest } from "next/server";
import { GET, POST } from "./route";

afterEach(() => vi.unstubAllGlobals());

function apiAnswers(status: number, body: unknown) {
  vi.stubGlobal(
    "fetch",
    vi.fn().mockResolvedValue(
      new Response(JSON.stringify(body), {
        status,
        headers: { "content-type": "application/json" },
      }),
    ),
  );
}

function browser(method: string, path: string, cookie = "optio_session=tok") {
  return new NextRequest(`http://localhost:3100${path}`, { method, headers: { cookie } });
}

/** The Set-Cookie the web sent for the session cookie, if any. */
function sessionCookie(res: Response): string | undefined {
  return res.headers.getSetCookie().find((c) => c.startsWith("optio_session="));
}

describe("the web's API proxy and the session cookie", () => {
  it("deletes the cookie once the API refuses its session, and passes the refusal on", async () => {
    apiAnswers(401, { error: "Invalid or expired session" });
    const res = await GET(browser("GET", "/api/tasks"));
    expect(res.status).toBe(401);
    expect(await res.json()).toEqual({ error: "Invalid or expired session" });
    expect(sessionCookie(res)).toMatch(/Max-Age=0/);
  });

  it("deletes the cookie on sign-out", async () => {
    apiAnswers(200, { ok: true });
    const res = await POST(browser("POST", "/api/auth/logout"));
    expect(sessionCookie(res)).toMatch(/Max-Age=0/);
  });

  it("keeps the cookie on another 401 and on success", async () => {
    apiAnswers(401, { error: "Wrong username or password" });
    expect(sessionCookie(await POST(browser("POST", "/api/auth/ldap/login")))).toBeUndefined();
    apiAnswers(200, { tasks: [] });
    expect(sessionCookie(await GET(browser("GET", "/api/tasks")))).toBeUndefined();
  });

  it("sets no cookie for a browser that had none", async () => {
    apiAnswers(401, { error: "Authentication required" });
    expect(sessionCookie(await GET(browser("GET", "/api/tasks", "")))).toBeUndefined();
  });
});
