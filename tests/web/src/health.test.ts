import { describe, expect, it, vi } from "vitest";
import { checkHealth } from "@/pages/api/health";

// /api/health is what the deploy's smoke and the bootstrap's probes read: ok
// only when the project this Worker was built for answers its key AND its
// Data API knows the `channels` table the migrations create — the chat runs
// in the browser, so nothing else on the Worker proves the project is bound
// and migrated.
function fetchFrom(routes: Record<string, Response | Error>) {
  return vi.fn(async (input: string | URL | Request) => {
    const url = String(input);
    for (const [prefix, answer] of Object.entries(routes)) {
      if (url.startsWith(prefix)) {
        if (answer instanceof Error) throw answer;
        return answer.clone();
      }
    }
    throw new Error(`unexpected fetch ${url}`);
  }) as unknown as typeof fetch;
}

const URL_ = "https://ref.supabase.co";
const KEY = "sb_publishable_test";

describe("checkHealth (pages/api/health.ts)", () => {
  it("is ok when Auth answers the key and the channels table is there", async () => {
    const f = fetchFrom({
      [`${URL_}/auth/v1/settings`]: Response.json({ disable_signup: false, mailer_autoconfirm: true }),
      [`${URL_}/rest/v1/channels?select=id&limit=1`]: Response.json([]),
    });
    expect(await checkHealth(URL_, KEY, f)).toEqual({
      ok: true, auth: "reachable", signup: "open", emailConfirmation: "off", schema: "migrated",
    });
    const calls = (f as unknown as { mock: { calls: [string, RequestInit][] } }).mock.calls;
    expect(calls.map(([u]) => u)).toEqual([
      `${URL_}/auth/v1/settings`,
      `${URL_}/rest/v1/channels?select=id&limit=1`,
    ]);
    // Read-only, as the anonymous role: the publishable key and nothing else.
    for (const [, init] of calls) {
      expect((init.headers as Record<string, string>).apikey).toBe(KEY);
      expect(init.method ?? "GET").toBe("GET");
    }
  });

  it("is not ok before the migrations ran (the Data API has no channels table)", async () => {
    const f = fetchFrom({
      [`${URL_}/auth/v1/settings`]: Response.json({ disable_signup: true }),
      [`${URL_}/rest/v1/channels`]: Response.json({ code: "PGRST205" }, { status: 404 }),
    });
    expect(await checkHealth(URL_, KEY, f)).toEqual({
      ok: false, auth: "reachable", signup: "closed", emailConfirmation: "required", schema: "not migrated",
    });
  });

  it("names a refused key", async () => {
    const f = fetchFrom({ [`${URL_}/auth/v1/settings`]: new Response("no", { status: 401 }) });
    expect(await checkHealth(URL_, KEY, f)).toEqual({ ok: false, auth: "key refused" });
  });

  it("is not ok when nothing is configured, and asks nobody", async () => {
    const f = fetchFrom({});
    expect(await checkHealth(undefined, KEY, f)).toEqual({ ok: false, auth: "not configured" });
    expect(await checkHealth(URL_, "", f)).toEqual({ ok: false, auth: "not configured" });
    expect((f as unknown as { mock: { calls: unknown[] } }).mock.calls).toHaveLength(0);
  });

  it("says unreachable when the project does not answer", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const f = fetchFrom({ [`${URL_}/auth/v1/settings`]: new Error("ECONNREFUSED") });
    expect(await checkHealth(URL_, KEY, f)).toEqual({ ok: false, auth: "unreachable" });
  });

  it("tolerates a trailing slash on the project URL", async () => {
    const f = fetchFrom({
      [`${URL_}/auth/v1/settings`]: Response.json({}),
      [`${URL_}/rest/v1/channels`]: Response.json([]),
    });
    expect((await checkHealth(`${URL_}/`, KEY, f)).ok).toBe(true);
  });
});
