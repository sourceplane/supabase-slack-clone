# supabase-slack-clone — design

## 1. What the example is

A Next.js 13-era **pages-router** app (`pages/_app.js`, `pages/index.js`,
`pages/channels/[id].js`) whose every Supabase call runs in the browser,
through one supabase-js client in `lib/Store.js`:

- **Auth** — email and password sign-up and sign-in (`pages/index.js`), the
  session kept by supabase-js; `_app.js` decodes the access token and reads
  its `user_role` claim to decide which delete buttons to show.
- **Data API** — `channels`, `messages` (with each author embedded as
  `author:user_id(*)`) and `users`, read and written under row-level
  security.
- **Realtime** — `postgres_changes` subscriptions on `messages`, `users` and
  `channels`, which stream what the `supabase_realtime` publication carries.

Its schema is two migrations and a seed (`supabase/migrations`,
`supabase/seed.sql`): the tables, an `app_role` enum, `user_roles` and
`role_permissions`, `public.authorize(permission)`, the policies, a trigger
that creates the `public.users` row (and, by plus-address, a role) for every
new Auth user, the publication with `replica identity full`, the custom
access-token hook, and two channels with a first message each.
`supabase/config.toml` switches the hook on
(`[auth.hook.custom_access_token]`).

Upstream deploys it with "Deploy with Vercel" and the Supabase integration,
then `supabase db push` and `supabase config push`.

## 2. What maps to what

| Upstream | Here | Why |
|---|---|---|
| Vercel, `next: latest` | `apps/web`, Next 16.3.8 pinned, `@opennextjs/cloudflare` → one Worker + Static Assets (`cloudflare-workers-assets-turbo`) | `latest` is not a build anyone can reproduce; the pages router builds and serves on OpenNext as it does on Vercel |
| The Vercel project's env vars | `NEXT_PUBLIC_SUPABASE_URL` / `_PUBLISHABLE_KEY` as wrangler vars, rendered per environment from `WIRING_SUPABASE`; `next build` reads them from the same `wrangler.jsonc` (`next.config.ts`) | `NEXT_PUBLIC_*` are inlined at build time, server code included, so the bundle and the Worker must name one project |
| A project from the Supabase integration | `infra/terraform/supabase` (supabase-starter's root): a project per environment, its Site URL and redirect allow-list set to the Worker, email confirmation off | A fresh, unattended deploy has nobody to click through a dashboard |
| `supabase db push` | `packages/db` (`@saas/db`): `000_control`, then `010_init`, `020_auth_hook`, `030_seed` — upstream's files byte for byte — applied by the `db-migrate` composition over the Management API's query endpoint, each recorded with its checksum in the project's `_migrations.applied` | One runner, one ledger, and a pull request that verifies every checksum offline |
| `seed.sql` | `030_seed`, a migration | The app sends a signed-in user to `/channels/1`: without the seed's `#public` there is nothing to land on. Applied once, like any migration |
| `supabase config push` of the hook | `packages/db/src/auth-config.ts`, PATCHed into the project's Auth config by the runner after the migrations, then read back | See §4 |
| — | `pages/api/health.ts` | The chat runs in the browser, so a page that renders proves only that the Worker deployed (§5) |

## 3. The env and secret flow

```
supabase apply ──publishes──▶ WIRING_SUPABASE (url, publishable key) ──▶ web: live.mjs renders wrangler.jsonc ──▶ next build inlines, Worker vars
              └─publishes──▶ SUPABASE_PROJECT_REF, _DB_PASSWORD, _DB_URL ──▶ db-migrate: secretEnv (fail-closed)
brokered ──▶ SUPABASE_ACCESS_TOKEN ──▶ supabase (provider) and db-migrate (query, config/auth)
brokered ──▶ CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID ──▶ web (deploy)
```

No service-role key is read from the project or published: nothing in the
product runs with it. `web` reads its wiring documents as
`optionalSecretEnv` — stage's deploy must not fail because prod's apply has
not published yet — and its build's render (`tooling/wire/live.mjs --env`)
fails the lane when this environment's document is missing. `dev` renders
nothing and builds against the committed fixture.

## 4. The auth-hook decision

The roles only work if Auth calls `public.custom_access_token_hook` on every
token it issues. Three places could switch it on:

1. **Terraform** (`supabase_settings.auth`, provider 1.5.1, which can set
   `hook_custom_access_token_enabled` / `_uri`). Rejected: the supabase root
   applies BEFORE db-migrate, so on a project's first apply Auth would point
   at a function that does not exist yet, and every sign-in would fail until
   the migrations ran. Ordering the root after db-migrate would invert the
   graph (db-migrate needs the project).
2. **A migration** — Auth's config is not in the database; SQL cannot set it.
3. **The migration runner, after the migrations** — chosen. It already holds
   the Management API token and runs exactly when the function has just been
   created. `PATCH /v1/projects/{ref}/config/auth` with the two keys, then a
   `GET` that must read them back, on every apply: idempotent, and it undoes
   a dashboard edit. A pull request's offline plan touches no Auth.

The two keys are the only Auth settings db-migrate writes; the supabase root
writes only `site_url`, `uri_allow_list` and `mailer_autoconfirm`. The two
never write the same key, so neither undoes the other.

## 5. The smoke

The deploy's smoke and the bootstrap's probe read `/api/health`, which the
Worker answers by asking the project two read-only questions with the key
the build inlined: Auth's public `/auth/v1/settings` (reachable, and how
sign-up behaves), and the Data API's `channels?select=id&limit=1` — 200
with no rows for the anonymous role once the migrations ran, 404 before. So
a green smoke says the Worker deployed, names a live project, and that
project has the chat's schema. Nothing is written; nothing leaks.

## 6. Out of scope

- Realtime's websocket on Cloudflare: the browser connects to Supabase
  directly; nothing on the Worker relays it.
- Vercel preview branches with Supabase branching: `dev` verifies pull
  requests; `stage` and `prod` each have a project.
- Changing the example's role model. The plus-address roles are upstream's
  demo convenience; the product's README says how to replace them.
