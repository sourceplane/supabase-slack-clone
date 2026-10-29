# supabase-slack-clone

Supabase's [Slack clone](https://github.com/supabase/supabase/tree/master/examples/slack-clone/nextjs-slack-clone)
— the Next.js example of a realtime team chat: channels, messages that
arrive live over Supabase Realtime, email and password sign-up through
Supabase Auth, and members, moderators and admins whose role rides in every
session through an Auth hook and is enforced by row-level security — running
on **Cloudflare Workers + Static Assets** through
[`@opennextjs/cloudflare`](https://opennext.js.org/cloudflare), with the
Supabase project itself provisioned by Terraform and its schema applied by
migrations through [Orun](https://github.com/sourceplane/orun), and packaged
as an **Orun baseline** in SL4: one command will take a new product from
nothing to live on stage and prod, in its own repository, under its own
name, in ONE landing.

The example's code is the code. What the port changes is what the Workers
runtime and a fresh, unattended deployment force: `next` pinned (upstream
says `latest`) and the two calls Next 16 and supabase-js 2 no longer accept
fixed, the build inlining the project's URL and publishable key from the
same wrangler config the Worker runs with (`next.config.ts`), upstream's two
migrations and its seed applied by db-migrate instead of `supabase db push`,
the access-token hook `supabase/config.toml` switched on set by that runner
through the Management API, each project created with its Auth pointed at
the Worker and email confirmation off (so anyone can sign up on the first
deploy, with no SMTP server), and a read-only `/api/health` only the Worker
can answer. What the baseline adds (SL4) is everything needed to make a copy
of it somebody else's — built the way
[supabase-starter](https://github.com/sourceplane/supabase-starter) builds a
product, in one landing. See
[`specs/epics/supabase-slack-clone`](specs/epics/supabase-slack-clone/README.md)
for the design, the milestones and the as-built status, including every
departure.

## What is here (the product)

| Surface | Where |
|---|---|
| The product's name | `apps/web/lib/site.ts` |
| Sign-in and sign-up, the channel pages, `/api/health` | `apps/web/pages` |
| The Supabase client, the data hooks and the Realtime subscriptions | `apps/web/lib/Store.js` |
| Workers build and deploy contract | `apps/web/next.config.ts`, `open-next.config.ts`, `wrangler.template.jsonc` → `wrangler.jsonc` (committed), `component.yaml` |
| The Supabase project (stage, prod), its Auth settings | `infra/terraform/supabase` |
| The schema — upstream's two migrations and its seed — the access-token hook's Auth config, and the runner | `packages/db`, applied by `infra/db-migrate` |
| Tests | `tests/web` (vitest), `tests/db` (vitest on PGlite) |

## Getting started

```bash
pnpm install
pnpm run wire:fixture   # re-render apps/web/wrangler.jsonc from its template (committed; this changes nothing)
pnpm typecheck
pnpm lint
pnpm test
pnpm build              # next build + opennextjs-cloudflare build → apps/web/.open-next
```

The build needs no Supabase project: without one it inlines the committed
`wrangler.jsonc`'s placeholder values, and nothing calls them.

## Running it locally

Against any Supabase project with the schema applied (its URL and
publishable key are in the dashboard → Project Settings → API):

1. Copy `apps/web/.env.example` to `apps/web/.env.local` and fill in the two
   values; `next dev` and `pnpm build` read it. Then
   `pnpm --filter @app/web dev` (http://localhost:3000).
2. Or the built Worker: the same two values in `apps/web/.dev.vars` (copy
   `.dev.vars.example`), `pnpm build`, then `pnpm --filter @app/web preview`
   (http://localhost:8787).

The schema comes from the runner the pipeline uses:
`pnpm --filter @saas/db build`, then
`SUPABASE_ACCESS_TOKEN=… SUPABASE_PROJECT_REF=… node packages/db/dist/runner/cli.js apply --env stage`
— every migration the project has not had, then the access-token hook.

## How it deploys

Merges to `main` converge through Orun (`.github/workflows/ci.yml`), per
environment in a fixed order — the Supabase project, then the migrations,
then the Worker — every edge enforced on a push to main and advisory on a
pull request. `stage` deploys first and `prod` once stage has converged;
`dev` only verifies. Each deploy is smoke-tested over HTTP, `/api/health`
included. The pipeline plans nothing while `intent.yaml` names the
placeholder workspace `ws_CHANGE_ME`, as this repository does.

## How it maps to Vercel and Supabase

| Upstream (Vercel + a Supabase project) | Here |
|---|---|
| Next.js `latest` on Vercel, the pages router | Next 16.3.8, pinned, built by OpenNext into one Cloudflare Worker (`.open-next/worker.js`) + Static Assets |
| "Deploy with Vercel" and the Supabase integration, which create the project and set its env vars | `orun new --blueprint repo-blueprint.yaml` — a new repository, branded; `infra/terraform/supabase` creates one project per environment and publishes its URL and keys as orun secrets |
| `NEXT_PUBLIC_SUPABASE_URL` / `_PUBLISHABLE_KEY` in the Vercel project | wrangler vars rendered per environment from the supabase root's `WIRING_SUPABASE`; `next build` inlines the same two from that config (`next.config.ts`) |
| `supabase db push` of `supabase/migrations`, and `seed.sql` | `packages/db/src/migrations` — `010_init`, `020_auth_hook`, `030_seed`, byte for byte — applied by the db-migrate component on every merge, before the app deploys |
| `[auth.hook.custom_access_token]` in `supabase/config.toml`, pushed with `supabase config push` | `packages/db/src/auth-config.ts`, set in the project's Auth by the same runner after the migrations (`PATCH /v1/projects/{ref}/config/auth`), so Auth never points at a function that does not exist yet |
| `site_url` and `enable_confirmations = true` in `config.toml` | The apply sets the Site URL and redirect allow-list to the Worker, and email confirmation off until the project has SMTP of its own (`authEmailConfirmation`), because the built-in email reaches only the organization's members |
| Preview branches, each with its own Supabase branch | A `dev` environment that verifies every pull request (the app built and dry-deployed, the migrations' checksums verified offline); `stage` and `prod` each have a project |

The publishable (anon) key is a wrangler var, not a secret: it is shipped to
every browser by design, and row-level security is the boundary. No
service-role key is read anywhere.

## CI

| Workflow | What it runs | Ships to a product |
|---|---|---|
| `ci.yml` | the Orun pipeline, and the only workflow a product carries: `orun plan --changed`, then one job per lane. A pull request runs the verify lanes (the app built and dry-deployed per environment, the Supabase root planned, the migrations planned offline; no typecheck, lint or tests), except the bootstrap's own landings (`orun/BASE-*`), where `plan` alone runs and nothing waits for it — the landing was checked in the build box; a merge applies, migrates and deploys stage → prod. It plans nothing while `intent.yaml` names the placeholder workspace `ws_CHANGE_ME`, as this repository does. A manual run (Orunbase's Deploy button, or Run workflow on `main`) plans the environment and components it names under the push-to-main trigger, so they deploy as a merge deploys them | yes |
| `tag.yml` | cuts a `baseline-vN` tag (manual) | no |

## Licence and credit

The app is Supabase's [Slack clone example](https://github.com/supabase/supabase/tree/master/examples/slack-clone/nextjs-slack-clone),
by [Supabase](https://supabase.com). Its own `package.json` says MIT; the
[supabase/supabase](https://github.com/supabase/supabase) repository it lives
in is licensed under the Apache License 2.0, which `apps/web/LICENSE` carries.
The migrations under `packages/db/src/migrations` are the example's own SQL,
under the same terms.
