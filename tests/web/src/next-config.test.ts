import { afterEach, describe, expect, it } from "vitest";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import * as path from "node:path";
import { PHASE_DEVELOPMENT_SERVER, PHASE_PRODUCTION_BUILD } from "next/constants";
import nextConfig, { supabaseBuildEnv } from "@/next.config";

// `next build` inlines NEXT_PUBLIC_* into the browser bundle, so the build
// must know the Supabase project — and must know the SAME one the Worker's
// wrangler vars name. next.config.ts reads them from wrangler.jsonc: the
// committed fixture render, or the one a deploy lane re-rendered from its
// wiring document just before it built.
const KEYS = ["NEXT_PUBLIC_SUPABASE_URL", "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY"] as const;
const saved = Object.fromEntries(KEYS.map((k) => [k, process.env[k]]));

afterEach(() => {
  for (const k of KEYS) {
    if (saved[k] === undefined) delete process.env[k];
    else process.env[k] = saved[k];
  }
});

describe("next.config.ts", () => {
  it("builds with the committed wrangler.jsonc's project when the environment names none", () => {
    for (const k of KEYS) delete process.env[k];
    const config = nextConfig(PHASE_PRODUCTION_BUILD);
    expect(config.env).toEqual({
      NEXT_PUBLIC_SUPABASE_URL: "https://stage-project-ref.supabase.co",
      NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: "sb_publishable_fixture_stage",
    });
    expect(config.reactStrictMode).toBe(true);
    expect(config.output).toBe("standalone");
  });

  it("lets a value in the environment (.env.local) win over the wrangler config", () => {
    process.env.NEXT_PUBLIC_SUPABASE_URL = "https://mine.supabase.co";
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY = "sb_publishable_mine";
    expect(nextConfig(PHASE_PRODUCTION_BUILD).env).toEqual({
      NEXT_PUBLIC_SUPABASE_URL: "https://mine.supabase.co",
      NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: "sb_publishable_mine",
    });
  });

  it("leaves `next dev` to .env.local, as upstream does", () => {
    for (const k of KEYS) delete process.env[k];
    expect(nextConfig(PHASE_DEVELOPMENT_SERVER).env).toEqual({});
  });

  it("reads the vars of a re-rendered config, comments, URLs and all", () => {
    const dir = mkdtempSync(path.join(tmpdir(), "next-config-"));
    try {
      const file = path.join(dir, "wrangler.jsonc");
      writeFileSync(
        file,
        [
          "// a comment with \"quotes\" and https://example.com",
          "{",
          '  "name": "x-web", /* inline */',
          '  "vars": {',
          '    "NEXT_PUBLIC_SUPABASE_URL": "https://abc.supabase.co", // trailing',
          '    "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY": "sb_publishable_a//b",',
          "  },",
          "}",
        ].join("\n"),
      );
      expect(supabaseBuildEnv({}, file)).toEqual({
        NEXT_PUBLIC_SUPABASE_URL: "https://abc.supabase.co",
        NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: "sb_publishable_a//b",
      });
      expect(supabaseBuildEnv({}, path.join(dir, "missing.jsonc"))).toEqual({});
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
