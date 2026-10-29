import type { NextApiRequest, NextApiResponse } from "next";

// Not upstream's: the deploy's smoke check and the bootstrap's probe read
// this. The chat itself runs in the browser, which talks to Supabase
// directly, so a page that renders proves only that the Worker deployed.
// This proves what the page never shows: the project URL and publishable key
// this Worker was built with name a live project whose Auth answers them, and
// its schema is there — the Data API knows the `channels` table the
// migrations create (row-level security gives an anonymous caller no rows,
// which is the point: read-only, nothing to leak). It also says how sign-up
// behaves there — open or closed, and whether a new user must confirm an
// email address first — from the project's own Auth settings, which
// supabase-js reads too: public data, answered only for a valid API key.
export type Health = {
  ok: boolean;
  auth: string;
  signup?: "open" | "closed";
  emailConfirmation?: "required" | "off";
  schema?: string;
};

export async function checkHealth(
  url: string | undefined,
  key: string | undefined,
  fetchImpl: typeof fetch = fetch,
): Promise<Health> {
  if (!url || !key) return { ok: false, auth: "not configured" };
  const base = url.replace(/\/+$/, "");
  const headers = { apikey: key, Authorization: `Bearer ${key}` };
  try {
    const auth = await fetchImpl(`${base}/auth/v1/settings`, {
      headers: { apikey: key },
      signal: AbortSignal.timeout(10_000),
    });
    if (!auth.ok) {
      return { ok: false, auth: auth.status === 401 ? "key refused" : `answered ${auth.status}` };
    }
    const settings = (await auth.json()) as { disable_signup?: boolean; mailer_autoconfirm?: boolean };
    const known = {
      auth: "reachable",
      signup: settings.disable_signup ? "closed" : "open",
      emailConfirmation: settings.mailer_autoconfirm ? "off" : "required",
    } as const;
    const rest = await fetchImpl(`${base}/rest/v1/channels?select=id&limit=1`, {
      headers,
      signal: AbortSignal.timeout(10_000),
    });
    if (!rest.ok) {
      return { ok: false, ...known, schema: rest.status === 404 ? "not migrated" : `answered ${rest.status}` };
    }
    return { ok: true, ...known, schema: "migrated" };
  } catch (error) {
    console.error("health: Supabase did not answer", error);
    return { ok: false, auth: "unreachable" };
  }
}

export default async function handler(_req: NextApiRequest, res: NextApiResponse<Health>) {
  const body = await checkHealth(
    process.env.NEXT_PUBLIC_SUPABASE_URL,
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
  );
  res.setHeader("cache-control", "no-store");
  res.status(body.ok ? 200 : 503).json(body);
}
