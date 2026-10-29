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
as an **Orun baseline**: one command takes a new product from nothing to
live on stage and prod, in its own repository, under its own name, in ONE
landing.

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
can answer. What the baseline adds is everything needed to make a copy of it
somebody else's — built the way
[supabase-starter](https://github.com/sourceplane/supabase-starter) builds a
product, in one landing. See [`specs/epics/supabase-slack-clone`](specs/epics/supabase-slack-clone/README.md)
for the design, the milestones and the as-built status, including every
departure.

## Instantiating a product

```bash
git clone --depth 1 --branch <baseline-tag> https://github.com/sourceplane/supabase-slack-clone
cd supabase-slack-clone
orun new --blueprint repo-blueprint.yaml --out ~/products/acme-chat --run-hooks --resume \
  --set reponame=acme-chat --set productname="Acme Chat" \
  --set githuborg=acme-inc --set subdomain=<workers-dev-subdomain>
```

Or, once the platform's registry lists it, from the Orun console (Baselines →
`supabase-slack-clone` → Build). Two phases: **`01-product`** creates the
repository, mints the four brokered credentials (Cloudflare and Supabase) and
lands the whole product as one pull request, whose convergence on `main`
provisions, migrates and deploys it per environment in a fixed order —

```
supabase ──▶ db-migrate ──▶ web
```

— every edge `mode: enforced` on a push to main and advisory on a pull
request; then **`02-docs`** records the live deployment from probed facts.
**[BOOTSTRAP.md](BOOTSTRAP.md)** is the operator guide;
[docs/phases/](docs/phases/README.md) has a page per phase. The Supabase
organization needs room for **two** projects (stage and prod) — the free
plan's limit.

The new repository receives the **product only** — the app, the Terraform
root, the migrations, the tests, its CI, its tooling, a README and an
AGENTS.md of its own and its operating contract — renamed throughout to the
product's name, repository, Worker and Supabase projects. None of this
repository's machinery ships.

| What makes it a baseline | Where |
|---|---|
| The console card (inputs, secrets, programme) | `blueprint.yaml` |
| The build document (modules, phases, hooks) | `repo-blueprint.yaml` |
| This tree's identity, the product's README and AGENTS.md, and the bootstrap's task contracts | `.baseline/` |
| The rename engine (product-name seam: `apps/web/lib/site.ts`) | `tooling/rebrand/rebrand.mjs` |
| The bootstrap's helpers (deferrals, redeploy marker, work-tree strip) | `tooling/bootstrap/` |
| The deployment-record renderer | `hooks/render-deployment-docs.sh` |
| The product's context pack | `ai/context/` |
| The baseline's tests: contract, leak, offline bootstrap and plans, end to end | `testing/`, `.github/workflows/baseline.yml` |
| Cutting a `baseline-vN` tag | `.github/workflows/tag.yml` |

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

The build needs no Supabase project. Running it against one — `.env.local`
for `next dev` and the build, `.dev.vars` for `wrangler dev` — is in the
product's README (`.baseline/product/README.md`), which is what a product
built from here carries.

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
| `baseline.yml` | the baseline's own tiers: contract tests; the blueprint read by the pinned orun, the leak gate, the offline bootstrap and the product's own plans; the 01-product landing installed, its fixture rendered, type-checked, linted, tested and built, then built in the job tree orun stages, dry-deployed, and served against a local Supabase stand-in — the smoke refused before the migrations, db-migrate's own steps applying them and the hook, then the smoke passing and the chat driven as a member, a moderator and an admin | no |
| `tag.yml` | cuts a `baseline-vN` tag (manual) | no |

## Licence and credit

The app is Supabase's [Slack clone example](https://github.com/supabase/supabase/tree/master/examples/slack-clone/nextjs-slack-clone),
by [Supabase](https://supabase.com). Its own `package.json` says MIT; the
[supabase/supabase](https://github.com/supabase/supabase) repository it lives
in is licensed under the Apache License 2.0, which `apps/web/LICENSE` carries.
The migrations under `packages/db/src/migrations` are the example's own SQL,
under the same terms.
