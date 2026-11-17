import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { api } from "./api-client";

const assign = vi.fn();

function at(pathname: string, search = "") {
  Object.defineProperty(window, "location", {
    configurable: true,
    value: { ...window.location, pathname, search, assign },
  });
}

function answer(status: number, error: string) {
  vi.stubGlobal(
    "fetch",
    vi.fn().mockResolvedValue({ ok: false, status, json: async () => ({ error }) }),
  );
}

beforeEach(() => at("/work", "?view=recurring"));
afterEach(() => {
  vi.unstubAllGlobals();
  assign.mockReset();
});

describe("a session the API no longer accepts", () => {
  it("sends the page to sign-in, back to where it was", async () => {
    answer(401, "Invalid or expired session");
    await expect(api.listTasks()).rejects.toThrow();
    expect(assign).toHaveBeenCalledWith("/login?redirect=%2Fwork%3Fview%3Drecurring");
  });

  it("stays put when a route needs a user and sign-in is turned off", async () => {
    answer(401, "Authentication required");
    await expect(api.listTasks()).rejects.toThrow();
    answer(401, "Not authenticated");
    await expect(api.listTasks()).rejects.toThrow();
    expect(assign).not.toHaveBeenCalled();
  });

  it("stays put on a page that works signed out", async () => {
    at("/login");
    answer(401, "Invalid or expired session");
    await expect(api.listTasks()).rejects.toThrow();
    expect(assign).not.toHaveBeenCalled();
  });

  it("stays put on any other refusal", async () => {
    answer(401, "Wrong username or password");
    await expect(api.listTasks()).rejects.toThrow();
    answer(403, "Requires admin role");
    await expect(api.listTasks()).rejects.toThrow();
    expect(assign).not.toHaveBeenCalled();
  });
});
