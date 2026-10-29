// The Supabase Auth settings this schema needs switched on in the project,
// applied by the migration runner right after the migrations — never before,
// because each names a database object a migration creates.
//
// Upstream sets this in supabase/config.toml ([auth.hook.custom_access_token])
// and pushes it with `supabase config push`. Here the runner PATCHes the
// project's Auth config through the Management API (the endpoint
// `config push` itself calls) once 020_auth_hook has created
// public.custom_access_token_hook — so from the first sign-in every access
// token carries the user's `user_role` claim, which the row-level security
// policies' public.authorize() and the app's delete buttons read.
//
// Only these keys are written; every other Auth setting stays the project's
// own (the `supabase` Terraform root manages site_url, uri_allow_list and
// mailer_autoconfirm, and never these).
export const authConfig = {
  hook_custom_access_token_enabled: true,
  hook_custom_access_token_uri: "pg-functions://postgres/public/custom_access_token_hook",
} as const;

export type AuthConfig = typeof authConfig;
