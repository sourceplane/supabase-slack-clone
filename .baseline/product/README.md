# supabase-slack-clone

Supabase's [Slack clone](https://github.com/supabase/supabase/tree/master/examples/slack-clone/nextjs-slack-clone)
— a team chat with channels, messages that arrive live over Supabase
Realtime, email and password sign-up, and moderator and admin roles carried
in every session by an Auth hook and enforced by row-level security — on
**Cloudflare Workers + Static Assets** through
[`@opennextjs/cloudflare`](https://opennext.js.org/cloudflare), with a
**Supabase** project per environment provisioned by Terraform and its schema
applied by migrations, on every merge to `main`.

## Live deployment

<!-- 02-docs:begin -->
Not recorded yet. The bootstrap's last phase writes the live URLs, the
workspace, how sign-up behaves on each environment and the secrets the
product uses into [ai/context/deployment.md](ai/context/deployment.md); how
the product deploys and how to operate it is in
[ai/context/operations.md](ai/context/operations.md).
<!-- 02-docs:end -->

## What is here

| Surface | Where |
|---|---|
| The product's name | `apps/web/lib/site.ts` |
| Sign-in and sign-up, the channel pages, `/api/health` | `apps/web/pages` |
| The Supabase client, the data hooks and the Realtime subscriptions | `apps/web/lib/Store.js` |
| The sidebar, a message, the message box | `apps/web/components` |
| Workers build and deploy contract | `apps/web/next.config.ts`, `open-next.config.ts`, `wrangler.template.jsonc` → `wrangler.jsonc`, `component.yaml` |
| The Supabase project (stage, prod) and its Auth settings | `infra/terraform/supabase` |
| The schema — tables, roles, policies, the access-token hook, the Realtime publication, the two starter channels — and its runner | `packages/db` (applied by `infra/db-migrate`) |
| Tests | `tests/web` (the app), `tests/db` (the schema, on Postgres in process) |

A coding agent starts at [AGENTS.md](AGENTS.md): what to read first, how a
change lands, and what not to touch.

## Getting started

```bash
pnpm install
pnpm run wire:fixture   # re-render apps/web/wrangler.jsonc from its template (it is committed)
pnpm typecheck
pnpm lint
pnpm test
pnpm build              # next build + opennextjs-cloudflare build → apps/web/.open-next
```

Run them before you push: a pull request's CI builds and dry-deploys the
app and plans the migrations, but type-checks, lints and tests nothing.

The build needs no Supabase project: without one it inlines the committed
`wrangler.jsonc`'s placeholder values, and nothing calls them.

## Running it locally

Against one of the product's own projects (stage is the natural one — its
URL and publishable key are in the Supabase dashboard → Project Settings →
API), or any Supabase project with the schema applied:

1. Copy `apps/web/.env.example` to `apps/web/.env.local` and fill in the two
   values. `next dev` and `pnpm build` read it.
2. Run Next's dev server —

   ```bash
   pnpm --filter @app/web dev          # http://localhost:3000
   ```

   — or the built Worker under `wrangler dev`, with the same two values in
   `apps/web/.dev.vars` (copy `.dev.vars.example`):

   ```bash
   pnpm build
   pnpm --filter @app/web preview      # http://localhost:8787
   ```

A project of your own gets the schema from the same runner the pipeline
uses — a Supabase access token and the project's ref in the environment,
then:

```bash
pnpm --filter @saas/db build
SUPABASE_ACCESS_TOKEN=… SUPABASE_PROJECT_REF=… node packages/db/dist/runner/cli.js apply --env stage
```

It applies every migration the project has not had, then switches on the
access-token hook.

## How it deploys

Merges to `main` converge through [Orun](https://github.com/sourceplane/orun):
`.github/workflows/ci.yml` plans the changed components and runs each lane
against the workspace in `intent.yaml`. Per environment the order is
enforced — **the Supabase project, then the migrations, then the Worker** —
because each reads what the one before it left: the migrations read the
project's ref and credentials, and the app's build reads the project's URL
and publishable key (`WIRING_SUPABASE`), renders them into the Worker's vars
and inlines them into the browser bundle, and talks to the tables the
migrations made. `stage` deploys first and `prod` once stage has converged
on the same commit; `dev` only verifies. Every deploy is smoke-tested over
HTTP, `/api/health` included, which answers only when the project's Auth
answers the key the build inlined and its Data API knows the chat's tables.

The pipeline holds one credential, GitHub's own `GITHUB_TOKEN`. The
Cloudflare token and account id and the Supabase access token and org id are
brokered per run from the workspace's connections; the project's URL and
publishable key and its database credentials are published by the Terraform
apply as orun secrets. Nothing provider-shaped is stored in the repository
or in GitHub, and no service-role key is read anywhere: the chat runs in the
browser with the publishable key, and row-level security is the boundary.

**Deploy by hand.** Orunbase's **Deploy** button on a component, or **Run
workflow** on the CI workflow in GitHub's Actions tab (on `main`), runs
`ci.yml` for the environment and components you pick, and each one deploys
exactly as a merge would deploy it. Leave the component blank to redeploy
every component in that environment, with nothing changed: after rotating a
secret, say. A component with nothing to run in that environment (a test
suite in `prod`) is left out with a notice.

## Roles

Every new user is a **member**: they read every channel and message, post,
and delete their own messages and the channels they created. Roles beyond
that are rows in `public.user_roles`, and each session carries the user's
role as its `user_role` claim — put there by the access-token hook
(`public.custom_access_token_hook`), which db-migrate switches on in each
project's Auth after the migrations. Row-level security reads the claim
through `public.authorize()`:

| role | may also |
|---|---|
| `moderator` | delete any message |
| `admin` | delete any message and any channel |

As upstream ships it, an address with `+supamod@` in it signs up as a
moderator and one with `+supaadmin@` as an admin (`handle_new_user`, the
trigger on `auth.users`). That is a demo's convenience — anyone can choose
such an address. Before real users arrive, replace it with a migration that
drops those two branches, and grant roles by inserting into
`public.user_roles` (Supabase dashboard → SQL editor) instead. A role takes
effect at the user's next sign-in or token refresh.

## Your first migration

A schema change is a new directory under `packages/db/src/migrations`
(`040_<name>/up.sql`), its entry in `packages/db/src/manifest.ts`, and
`pnpm --filter @saas/db run manifest:fix` to write its checksum. Merge it and
db-migrate applies it, stage then prod, before the app deploys. An applied
migration is never edited: the runner compares every file with its checksum
and with the project's own ledger, and refuses a changed one. A table in
`public` gets row-level security and its policies in the migration that
creates it; a table the chat should stream joins the `supabase_realtime`
publication there too, with `replica identity full` if a delete must carry
the row. `tests/db` runs every migration on Postgres in process and holds the
policies to their roles.

## Email

A Supabase project without an SMTP server of its own emails only the members
of its organization, a few times an hour. So each project is created with
email confirmation **off**: a new user is signed in the moment they sign up,
and anyone can.

To require confirmation, give each project SMTP of its own (Supabase
dashboard → Authentication → Emails → SMTP Settings), then set
`authEmailConfirmation: "true"` in `infra/terraform/supabase/component.yaml`
and merge. The sign-in page then tells a new user to look for the email, and
the link brings them back to the app, the project's Site URL.

## Custom domain

The app answers on workers.dev from its first deploy. To serve it on your
own domain:

1. Attach the domain to the Worker in Cloudflare (Workers & Pages →
   `supabase-slack-clone-web-prod` → Settings → Domains & Routes).
2. Set `SITE_URL: https://<your-domain>` under `environments.prod.env` in
   `intent.yaml`. It is the one setting for the product's origin: the
   supabase apply makes it the project's Auth Site URL and redirect
   allow-list, where Supabase's emails send people.
3. Redeploy the project: change the last line of
   `infra/terraform/supabase/component.yaml` (`# orun: redeploy …`) in the
   same pull request — a change to `intent.yaml` alone plans nothing.

The apply owns the project's Auth URLs: an edit in the Supabase dashboard is
undone by the next apply.

The repository also names the domain in one place, `BASE_DOMAIN` under each
environment's `env:` in `intent.yaml`, which the product was born with as the
reserved placeholder `supabase-slack-clone.example.com`. Nothing builds a URL
from it — the origin is `SITE_URL` — so replacing it moves nothing by itself;
it records the domain. Replace it with yours in the same pull request as
`SITE_URL`.

## CI

| Workflow | What it runs |
|---|---|
| `ci.yml` | the Orun pipeline, and the only workflow: `orun plan --changed`, then one job per lane. A pull request runs the verify lanes — the app built and dry-deployed for each environment, the Supabase root checked and planned, the migrations' checksums verified offline — with nothing applied or deployed (typecheck, lint and the tests are `pnpm` scripts you run before you push, above); a merge applies and deploys stage → prod |

## Licence

The app is Supabase's example, under the Apache License 2.0 of the
[supabase/supabase](https://github.com/supabase/supabase) repository it
lives in (`apps/web/LICENSE`); its own `package.json` says MIT. The rest of
this repository is the product's.
