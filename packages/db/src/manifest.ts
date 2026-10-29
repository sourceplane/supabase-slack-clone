import type { MigrationManifest } from "./types.js";

// Every migration the runner applies, in order, with the sha256 of its file.
// `pnpm --filter @saas/db run manifest:check` verifies the checksums;
// `manifest:fix` rewrites them after a migration file changes (only ever
// before that migration has been applied anywhere — an applied migration's
// checksum is immutable).
export const manifest: MigrationManifest = {
  version: 1,
  migrations: [
    {
      id: "000_control_baseline",
      context: "control",
      path: "000_control/up.sql",
      checksum:
        "2a5d7f30684c99e3ff441ca8a2c38038dedd1bab4db4a40e92cd36bb22be297f",
      description:
        "Baseline control migration — creates the migration tracking schema",
    },
    {
      id: "010_init",
      context: "app",
      path: "010_init/up.sql",
      checksum:
        "aa334acde2ceed2169b499969bdf7cba6eb2ee3fb70d8f9a3441d8c6ed625fd9",
      description:
        "The example's schema (supabase/migrations/20240214102356_init.sql, verbatim): users, channels, messages, user_roles and role_permissions with row-level security, public.authorize() for role-based deletes, the trigger that gives every new auth.users row a profile (and a role by plus-address), and the supabase_realtime publication over channels, messages and users",
    },
    {
      id: "020_auth_hook",
      context: "app",
      path: "020_auth_hook/up.sql",
      checksum:
        "4da1507129a1d0f73658577f9852b9969b501cf8f1dc65133ca89788fd4bfff6",
      description:
        "The custom access-token hook (supabase/migrations/20240214114147_auth-hook.sql, verbatim): public.custom_access_token_hook adds the user's role to every access token, readable by supabase_auth_admin only; the runner enables it in the project's Auth config after this applies (src/auth-config.ts)",
    },
    {
      id: "030_seed",
      context: "app",
      path: "030_seed/up.sql",
      checksum:
        "4786f8af13181723968fde859a617e9cd0fcd9f94e937d45e96327e02b99a46d",
      description:
        "The example's seed (supabase/seed.sql, verbatim): the admin and moderator permissions, and the #public and #random channels with a first message each, posted by a bot user who cannot sign in",
    },
  ],
};
