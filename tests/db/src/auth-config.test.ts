import { afterEach, describe, expect, it, vi } from "vitest";
import { authConfig } from "@saas/db";
import { SupabaseApiAdapter } from "@saas/db/runner";

// The Auth setting this schema needs and upstream sets in config.toml: the
// custom access-token hook, pointed at the function 020_auth_hook creates.
// The runner switches it on through the Management API after the migrations
// (src/runner/cli.ts), and refuses a project that did not keep it.
afterEach(() => vi.unstubAllGlobals());

describe("the Auth config the runner applies (packages/db/src/auth-config.ts)", () => {
  it("is upstream's hook, by the URI Auth resolves to the migrated function", () => {
    expect(authConfig).toEqual({
      hook_custom_access_token_enabled: true,
      hook_custom_access_token_uri: "pg-functions://postgres/public/custom_access_token_hook",
    });
  });

  it("names a function a migration creates", async () => {
    const { readFileSync } = await import("node:fs");
    const path = await import("node:path");
    const sql = readFileSync(path.resolve(__dirname, "../../../packages/db/src/migrations/020_auth_hook/up.sql"), "utf8");
    expect(sql).toMatch(/create or replace function public\.custom_access_token_hook\(event jsonb\)/);
    expect(sql).toMatch(/grant execute\s+on function public\.custom_access_token_hook\s+to supabase_auth_admin/);
  });

  it("PATCHes exactly those keys to the project's Auth config, then checks the project kept them", async () => {
    const seen: Array<{ method: string; url: string; body?: unknown; auth: string | null }> = [];
    let stored: Record<string, unknown> = { site_url: "https://x.example" };
    vi.stubGlobal("fetch", vi.fn(async (url: string, init: RequestInit = {}) => {
      const method = init.method ?? "GET";
      const body = init.body ? JSON.parse(String(init.body)) : undefined;
      seen.push({ method, url, body, auth: new Headers(init.headers).get("authorization") });
      if (method === "PATCH") stored = { ...stored, ...body };
      return Response.json(stored);
    }));
    const keys = await new SupabaseApiAdapter("abcdefghijklmnopqrst", "sbp_token").configureAuth(authConfig);
    expect(keys).toEqual(Object.keys(authConfig));
    expect(seen).toEqual([
      { method: "PATCH", url: "https://api.supabase.com/v1/projects/abcdefghijklmnopqrst/config/auth", body: authConfig, auth: "Bearer sbp_token" },
      { method: "GET", url: "https://api.supabase.com/v1/projects/abcdefghijklmnopqrst/config/auth", body: undefined, auth: "Bearer sbp_token" },
    ]);
  });

  it("refuses a project whose Auth config did not keep the hook", async () => {
    vi.stubGlobal("fetch", vi.fn(async (_url: string, init: RequestInit = {}) =>
      (init.method === "PATCH" ? Response.json({}) : Response.json({ hook_custom_access_token_enabled: false }))));
    await expect(new SupabaseApiAdapter("ref", "t").configureAuth(authConfig)).rejects.toThrow(
      /did not keep hook_custom_access_token_enabled, hook_custom_access_token_uri/,
    );
  });

  it("names the status when the Management API refuses the PATCH", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response("forbidden", { status: 403 })));
    await expect(new SupabaseApiAdapter("ref", "t").configureAuth(authConfig)).rejects.toThrow(/PATCH config\/auth answered HTTP 403: forbidden/);
  });
});
