# supabase-slack-clone — operating contract (for humans and agents)

This is the standing guide to how this product is deployed and operated.
Instance facts (live URLs, workspace, how sign-up behaves on each
environment, the secrets it uses) live in [deployment.md](deployment.md),
rendered from probed reality by the bootstrap's `02-docs` phase; this file is
the contract that stays true between deployments. It is written to give an
agent with repository read access enough context to reason about and operate
the product without any other source.

## What this system is

Supabase's Slack clone — a team chat with channels, messages that arrive
live, email and password sign-up, and moderator and admin roles — on
Cloudflare Workers, its Auth, its data and its Realtime a Supabase project
per environment, expressed as an Orun component-native desired-state repo.
Six components:

- **`infra/terraform/supabase`** (`supabase`) — one Supabase project per
  environment, its Auth's Site URL and redirect allow-list pointed at the
  app's Worker, and sign-up confirming at once unless `authEmailConfirmation`
  is on (below). Its apply publishes `WIRING_SUPABASE` (the project URL and
  publishable key) and `SUPABASE_PROJECT_REF`, `SUPABASE_DB_PASSWORD`,
  `SUPABASE_DB_URL` onto the environment's secret rung.
- **`infra/db-migrate`** (`db-migrate`) — applies `packages/db`'s migrations
  to that project over the Management API's query endpoint, records each in
  the project's own ledger (`_migrations.applied`), then switches on the
  access-token hook the chat's roles need in the project's Auth config
  (`packages/db/src/auth-config.ts`). A pull request plans it offline: every
  file's checksum against the manifest, nothing touched.
- **`packages/db`** (`db`) — the migrations, their manifest and the runner.
- **`apps/web`** (`web`) — the app: Next.js (pages router) built by
  `@opennextjs/cloudflare` into one Worker plus Static Assets. The chat runs
  in the browser, which talks to Supabase directly with supabase-js — Auth,
  the Data API and Realtime — never a Postgres connection. The Worker serves
  the pages and `/api/health`.
- **`tests/web`**, **`tests/db`** — the vitest suites (`pnpm test`): the app,
  and the schema on Postgres in process. Their `dev` lanes install them and
  check their structure; they do not run the tests, so run them (and
  `pnpm typecheck`, `pnpm lint`) before you push.

Environments: **`stage`** and **`prod`** are deployed; **`dev` is
verify-only by design** — lanes build and verify, nothing deploys.

## Identity and tenancy

Every remote operation runs against ONE Orun workspace, declared in
`intent.yaml` under `execution.state.workspace` — committed, enforced, and
what CI uses. Do not remove it; headless credentials depend on it. If it
reads `ws_SET_ME`, the bootstrap had no workspace to write: set the real one
before anything else.

## How deployment works

1. Merge (or push) to `main`.
2. CI (`.github/workflows/ci.yml`) runs `orun plan --changed` — only
   components whose files changed are planned — then runs each planned lane
   with `orun run --remote-state`, authenticated by GitHub OIDC (the
   exchange resolves this repository's linked workspace server-side).
3. Per environment, in this order — every edge `mode: enforced` on a push to
   main, advisory on a pull request (which deploys nothing):
   **`supabase` → `db-migrate` → `web`.** A job resolves its secrets when it
   starts, so db-migrate reads the database credentials the apply before it
   published, and the app's deploy reads `WIRING_SUPABASE`. It re-renders
   `apps/web/wrangler.jsonc` from that document, builds — `next build`
   inlines the same URL and key into the browser bundle (`next.config.ts`)
   — deploys `supabase-slack-clone-web-<env>`, and smoke-tests it: the
   sign-in page, and `/api/health`, which answers 200 only when the project's
   Auth answers the key the build inlined and its Data API knows the
   `channels` table the migrations create.
4. `prod` deploys after `stage` has converged on the same commit
   (`environments.prod.promotion` in intent.yaml).
5. **The convergence run is the deployment.** A green run means every
   planned lane applied. Failed lanes are retried with
   `gh run rerun --failed`, which resumes the same execution.

Caveats that matter:

- A push that touches no component files plans zero lanes — that run is
  green and deployed nothing. Never treat "latest run green" as "product
  converged"; probe the URLs instead.
- `apps/web/wrangler.jsonc` is committed as the render of
  `wrangler.template.jsonc` from `wiring.fixture.json` (a placeholder
  project): edit the template and run `pnpm run wire:fixture`. The deploy
  lanes render the real one in their own job tree; never commit a real
  project's URL or key.
- The product's origin is ONE setting. Unset, it is the environment's
  workers.dev URL (`<repo>-web-<env>.<subdomain>.workers.dev`); with a custom
  domain, `SITE_URL` under the environment's `env:` in `intent.yaml`. The
  supabase apply makes it Auth's Site URL and redirect allow-list, where
  Supabase sends its links (confirmation, when it is on). The apply owns
  those Auth settings: an edit in the dashboard is undone by the next apply.

## Auth, roles and email

Every new user is a member. The chat's other roles are rows in
`public.user_roles` (`moderator`, `admin`); the permissions each grants are
rows in `public.role_permissions` (`messages.delete` for both,
`channels.delete` for admins). The access-token hook
`public.custom_access_token_hook` copies the user's role into every access
token as the `user_role` claim, and `public.authorize(<permission>)` reads
that claim in the delete policies. The app reads the same claim
(`pages/_app.js`) to show the delete buttons; row-level security is what
enforces them.

The hook must be ON in the project's Auth config, and only db-migrate turns
it on — after the migrations, every apply, so the function exists before
Auth points at it, and a dashboard edit is undone by the next deploy. The
supabase root never writes those two keys.

As upstream ships it, `handle_new_user` (the trigger on `auth.users`) gives
an address containing `+supamod@` the moderator role and one containing
`+supaadmin@` the admin role. Anyone can choose such an address: before real
users arrive, replace that trigger in a new migration and grant roles by
inserting into `public.user_roles` instead. A new role reaches a session at
its next sign-in or token refresh.

A Supabase project without an SMTP server of its own delivers email only to
the members of its organization, a few messages an hour. So the supabase
root turns email confirmation OFF (`authEmailConfirmation: "false"` in its
component.yaml): sign-up signs a new user straight in, and works for anyone
on the first deploy. To require confirmation, give each project SMTP of its
own (Supabase dashboard → Authentication → Emails → SMTP Settings), then set
`authEmailConfirmation: "true"` and merge; `/api/health` and the deployment
record then say `emailConfirmation: required`.

The terraform manages only `site_url`, `uri_allow_list` and
`mailer_autoconfirm`; db-migrate manages the access-token hook; every other
Auth setting is the project's own.

## Data, row-level security and Realtime

Three tables in `public` carry the chat — `users` (one row per Auth user,
written by `handle_new_user`), `channels` and `messages` — plus `user_roles`
and `role_permissions`. Row-level security is on for every one of them:
signed-in users read every channel, message and user; each writes only as
themselves; deletes follow the roles above; the anonymous role reads
nothing. Keep that rule for every table you add to `public`: the
publishable key is public by design, so a table without RLS is readable by
anyone who loads the site. Check with:

```sql
select relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and c.relkind in ('r','p') and not c.relrowsecurity;
```

The browser subscribes to `channels`, `messages` and `users` through
Realtime, which streams what the `supabase_realtime` publication carries;
the migrations put those three tables in it with `replica identity full`, so
a deleted row reaches the browser whole. A table added to the chat joins the
publication in its own migration.

`030_seed` creates `#public` and `#random` and their first messages under a
bot user who cannot sign in. The app sends a signed-in user to
`/channels/1`, so `#public` is not to be deleted.

## Secrets model

- **Brokered provider secrets**, minted per run from the workspace's
  connections — no long-lived values at rest, nothing to rotate by hand:
  `CLOUDFLARE_API_TOKEN` (Workers deploy), `CLOUDFLARE_ACCOUNT_ID`,
  `SUPABASE_ACCESS_TOKEN` (project create, API keys, Auth settings, the
  migrations and the hook) and `SUPABASE_ORG_ID`.
- **Published by the apply** onto the stage and prod rungs:
  `WIRING_SUPABASE` (URL and publishable key — what the app reads),
  `SUPABASE_PROJECT_REF`, `SUPABASE_DB_PASSWORD`, `SUPABASE_DB_URL` (the
  database — what db-migrate reads). The service-role key is never
  published, and nothing reads one.
- **No Worker secrets.** The publishable key is a wrangler var: it ships to
  every browser by design, and row-level security is the boundary.
- Inspect by NAME only: `orun secrets list --org <ws> --project` and
  `--env stage|prod`. No tooling in this repository prints a secret value,
  and no document in `ai/context/` may contain one.

## Verifying the system

```bash
# the app and its health check on each environment (also recorded, probed, in deployment.md)
curl -s -o /dev/null -w '%{http_code}\n' https://supabase-slack-clone-web-stage.your-workers-subdomain.workers.dev/
curl -s https://supabase-slack-clone-web-prod.your-workers-subdomain.workers.dev/api/health

# workspace readiness (integrations + repository link)
orun integrations list --org <ws> --json && orun cloud check --org <ws>
```

## Common operations

| task | how |
|---|---|
| deploy a change | merge to `main`; watch the run; failed lanes → `gh run rerun --failed` |
| deploy by hand | Orunbase's Deploy button, or `gh workflow run ci.yml --ref main -f environment=<env> [-f component=<a,b>]` — the named components (blank: every one) run in that environment as a merge runs them; started off `main` it is refused |
| change the schema | a new `packages/db/src/migrations/<NNN>_<name>/up.sql`, its manifest entry, `pnpm --filter @saas/db run manifest:fix`, and `pnpm test` (tests/db runs every migration); merge — db-migrate applies it before the app deploys. Never edit an applied one |
| grant a role | `insert into public.user_roles (user_id, role) values ('<uuid>', 'moderator')` in the SQL editor, or a migration; it reaches the user's session at the next sign-in |
| require email confirmation | SMTP first, then `authEmailConfirmation: "true"` (above) |
| redeploy without a change | edit the last line of the component's `component.yaml` (`# orun: redeploy <reason> <stamp>`) and merge — it is a deploy trigger, nothing reads it |
| serve a custom domain | attach it to the Worker in Cloudflare (README, "Custom domain"), set `SITE_URL` under `environments.prod.env` in `intent.yaml`, replace the placeholder `supabase-slack-clone.example.com` in `intent.yaml`'s `BASE_DOMAIN` with it (a record; nothing builds a URL from it), and touch the redeploy line of `infra/terraform/supabase/component.yaml` in the same PR (an `intent.yaml` change alone plans nothing) |
| headless credentials | `ORUN_TOKEN` (workspace-scoped) + `GITHUB_TOKEN` |

The deployment record is the bootstrap's `02-docs` phase. Re-running it (the
Orun console's Retry on that phase, or `orun new … --phase 02-docs`)
re-probes the URLs and re-renders [deployment.md](deployment.md); it is
idempotent.

## Evolution

Structural changes (a second Worker, a queue, a storage bucket) follow the
same contract that deployed the product: add a component under `apps/`,
`infra/` or `packages/` with a `component.yaml` — declaring `dependsOn` on
any infrastructure whose published secrets it reads, enforced on main — land
it as a pull request, and the convergence run applies it.
