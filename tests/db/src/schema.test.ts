import { beforeAll, describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import * as path from "node:path";
import { PGlite } from "@electric-sql/pglite";
import { manifest } from "@saas/db/manifest";
import { SUPABASE_PRELUDE } from "./supabase";

// The schema the chat reads, as every migration db-migrate applies leaves it
// on a Supabase-shaped Postgres (PGlite, in process): five tables with
// row-level security, profiles and roles made by the trigger on auth.users,
// deletes decided by the `user_role` claim the access-token hook adds, the
// realtime publication over the three tables the browser listens to, and the
// seed's two channels.
const migrationsDir = path.resolve(__dirname, "../../../packages/db/src/migrations");

async function migrated(): Promise<PGlite> {
  const db = new PGlite();
  await db.exec(SUPABASE_PRELUDE);
  for (const entry of manifest.migrations) {
    await db.exec(readFileSync(path.join(migrationsDir, entry.path), "utf8"));
  }
  return db;
}

type Claims = { sub?: string; role: string; user_role?: string | null };

async function as<T>(db: PGlite, claims: Claims, fn: () => Promise<T>): Promise<T> {
  await db.exec(`set role ${claims.role}`);
  await db.query("select set_config('request.jwt.claims', $1, false)", [JSON.stringify(claims)]);
  try {
    return await fn();
  } finally {
    await db.exec("reset role");
    await db.query("select set_config('request.jwt.claims', '', false)");
  }
}

async function denied(p: Promise<unknown>): Promise<string> {
  try {
    await p;
    return "allowed";
  } catch (e) {
    return String(e);
  }
}

const ALICE = "00000000-0000-4000-8000-00000000a11c"; // a member
const ADMIN = "00000000-0000-4000-8000-0000000ad111"; // signed up with +supaadmin@
const MOD = "00000000-0000-4000-8000-00000000600d"; // signed up with +supamod@

describe("the chat's schema after every migration", () => {
  let db: PGlite;
  beforeAll(async () => {
    db = await migrated();
    await db.query(
      "insert into auth.users (id, email) values ($1, 'alice@example.invalid'), ($2, 'ann+supaadmin@example.invalid'), ($3, 'mo+supamod@example.invalid')",
      [ALICE, ADMIN, MOD],
    );
  }, 60_000);

  it("has upstream's five tables, each with row-level security", async () => {
    const { rows } = await db.query<{ relname: string; relrowsecurity: boolean }>(
      "select relname, relrowsecurity from pg_class where relnamespace = 'public'::regnamespace and relkind = 'r' order by relname",
    );
    expect(rows).toEqual(
      ["channels", "messages", "role_permissions", "user_roles", "users"].map((relname) => ({ relname, relrowsecurity: true })),
    );
  });

  it("gives every new auth user a profile, and a role by plus-address", async () => {
    const users = await db.query<{ id: string; username: string; status: string }>(
      "select id, username, status from public.users where id = any($1) order by username",
      [[ALICE, ADMIN, MOD]],
    );
    expect(users.rows.map((u) => u.username)).toEqual([
      "alice@example.invalid",
      "ann+supaadmin@example.invalid",
      "mo+supamod@example.invalid",
    ]);
    expect(new Set(users.rows.map((u) => u.status))).toEqual(new Set(["OFFLINE"]));
    const roles = await db.query<{ user_id: string; role: string }>(
      "select user_id, role::text from public.user_roles order by role",
    );
    expect(roles.rows).toEqual(
      expect.arrayContaining([
        { user_id: ADMIN, role: "admin" },
        { user_id: MOD, role: "moderator" },
      ]),
    );
    expect(roles.rows.find((r) => r.user_id === ALICE)).toBeUndefined();
  });

  it("seeds the #public and #random channels with a message each, and the role permissions", async () => {
    const channels = await db.query<{ id: number; slug: string }>("select id, slug from public.channels order by id");
    expect(channels.rows).toEqual([
      { id: 1, slug: "public" },
      { id: 2, slug: "random" },
    ]);
    const messages = await db.query<{ n: number }>("select count(*)::int as n from public.messages");
    expect(messages.rows[0]?.n).toBe(2);
    const perms = await db.query<{ role: string; permission: string }>(
      "select role::text, permission::text from public.role_permissions order by role, permission",
    );
    expect(perms.rows).toEqual([
      { role: "admin", permission: "channels.delete" },
      { role: "admin", permission: "messages.delete" },
      { role: "moderator", permission: "messages.delete" },
    ]);
  });

  it("adds the user's role to an access token through the hook, as Auth runs it", async () => {
    const event = (uid: string) => JSON.stringify({ user_id: uid, claims: { sub: uid, role: "authenticated" } });
    await db.exec("set role supabase_auth_admin");
    try {
      const run = async (uid: string) =>
        (await db.query<{ e: { claims: { user_role: string | null } } }>(
          "select public.custom_access_token_hook($1::jsonb) as e",
          [event(uid)],
        )).rows[0]?.e.claims.user_role;
      expect(await run(ADMIN)).toBe("admin");
      expect(await run(MOD)).toBe("moderator");
      expect(await run(ALICE)).toBeNull();
    } finally {
      await db.exec("reset role");
    }
  });

  it("lets nobody but Auth run the hook or read the roles table", async () => {
    for (const role of ["anon", "authenticated"]) {
      expect(await as(db, { role, sub: ALICE }, () => denied(db.query("select public.custom_access_token_hook('{}'::jsonb)")))).toMatch(/permission denied/);
      expect(await as(db, { role, sub: ADMIN }, () => denied(db.query("select * from public.user_roles")))).toMatch(/permission denied/);
    }
  });

  it("shows the anon key nothing", async () => {
    for (const table of ["users", "channels", "messages", "role_permissions"]) {
      const { rows } = await as(db, { role: "anon" }, () => db.query(`select * from public.${table}`));
      expect(rows, table).toEqual([]);
    }
  });

  it("lets a signed-in member read everything, post as themselves only, and delete only their own message", async () => {
    const alice: Claims = { role: "authenticated", sub: ALICE, user_role: null };
    const seen = await as(db, alice, () => db.query<{ n: number }>("select count(*)::int as n from public.messages"));
    expect(seen.rows[0]?.n).toBeGreaterThanOrEqual(2);
    const mine = await as(db, alice, () =>
      db.query<{ id: number }>("insert into public.messages (message, user_id, channel_id) values ('hi', $1, 1) returning id", [ALICE]),
    );
    expect(await as(db, alice, () => denied(db.query("insert into public.messages (message, user_id, channel_id) values ('as admin', $1, 1)", [ADMIN])))).toMatch(/row-level security/);
    // Someone else's message: the delete matches nothing under RLS.
    const theirs = await db.query<{ id: number }>("select id from public.messages where user_id <> $1 order by id limit 1", [ALICE]);
    const gone = await as(db, alice, () => db.query("delete from public.messages where id = $1", [theirs.rows[0]!.id]));
    expect(gone.affectedRows).toBe(0);
    const own = await as(db, alice, () => db.query("delete from public.messages where id = $1", [mine.rows[0]!.id]));
    expect(own.affectedRows).toBe(1);
  });

  it("lets a moderator delete any message and an admin any channel, by the token's user_role", async () => {
    const msg = await db.query<{ id: number }>("insert into public.messages (message, user_id, channel_id) values ('spam', $1, 2) returning id", [ALICE]);
    const mod: Claims = { role: "authenticated", sub: MOD, user_role: "moderator" };
    expect((await as(db, mod, () => db.query("delete from public.messages where id = $1", [msg.rows[0]!.id]))).affectedRows).toBe(1);
    const chan = await db.query<{ id: number }>("insert into public.channels (slug, created_by) values ('alices', $1) returning id", [ALICE]);
    expect((await as(db, mod, () => db.query("delete from public.channels where id = $1", [chan.rows[0]!.id]))).affectedRows).toBe(0);
    const admin: Claims = { role: "authenticated", sub: ADMIN, user_role: "admin" };
    expect((await as(db, admin, () => db.query("delete from public.channels where id = $1", [chan.rows[0]!.id]))).affectedRows).toBe(1);
  });

  it("publishes channels, messages and users to Realtime, with their previous rows", async () => {
    const pub = await db.query<{ tablename: string }>(
      "select tablename from pg_publication_tables where pubname = 'supabase_realtime' order by tablename",
    );
    expect(pub.rows.map((r) => r.tablename)).toEqual(["channels", "messages", "users"]);
    const ident = await db.query<{ relname: string; relreplident: string }>(
      "select relname, relreplident from pg_class where relname in ('channels', 'messages', 'users') and relnamespace = 'public'::regnamespace order by relname",
    );
    expect(ident.rows.every((r) => r.relreplident === "f")).toBe(true);
  });
});
