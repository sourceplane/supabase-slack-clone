# supabase-slack-clone — implementation status (as built)

What shipped, milestone by milestone, kept apart from the plan. Upstream is
[supabase/supabase `examples/slack-clone/nextjs-slack-clone`](https://github.com/supabase/supabase/tree/master/examples/slack-clone/nextjs-slack-clone)
at `9eaae4cd2cf8e67f9aeadab044e9a14429331c13`.

| Milestone | Pull request | State |
|---|---|---|
| SL0 — the spec | [#1](https://github.com/sourceplane/supabase-slack-clone/pull/1) | ✅ merged |
| SL1 — the chat app on Workers | [#2](https://github.com/sourceplane/supabase-slack-clone/pull/2) | ✅ merged |
| SL2 — the Supabase project and the schema | [#3](https://github.com/sourceplane/supabase-slack-clone/pull/3) | ✅ merged |
| SL3 — ready to instantiate | [#4](https://github.com/sourceplane/supabase-slack-clone/pull/4) | ✅ merged |
| SL4 — a baseline | [#5](https://github.com/sourceplane/supabase-slack-clone/pull/5) | ✅ merged, tagged `baseline-v1` |

Proven offline (Baseline CI, against a local Supabase stand-in); the
Terraform apply, the migrations and the deploy are gated until a workspace
is linked, and no live bootstrap has run (risk SL-A).

## Departures from upstream

Every change to the example's own code, and why. Everything else under
`apps/web` — `lib/Store.js`, `lib/UserContext.js`, the components, the
styles, `public/`, the Tailwind and PostCSS config — is upstream's, byte for
byte.

| Where | Upstream | Here | Why |
|---|---|---|---|
| `package.json` | `next: latest`, React 18, `next build` | `next` 16.3.8 pinned, React 19, OpenNext's build, `@app/web` | A reproducible build; the Workers runtime |
| `components/Layout.js` | `<Link …><a className=…>{slug}</a></Link>` | the class on `<Link>`, the slug its child | Next ≥ 13 renders the anchor itself and refuses a nested `<a>` |
| `pages/_app.js` | `const { subscription } = supabase.auth.onAuthStateChange(…)` | `const { data: { subscription } } = …` | supabase-js 2 nests the subscription under `data`; upstream's unsubscribe threw on unmount |
| `pages/_app.js` | `export default function SupabaseSlackClone` | `ChatApp` | The upstream name spells this repository's slug in PascalCase, which no rule renames and the rebrand's sweep refuses in a product |
| `pages/_app.js`, `pages/index.js` | no `<title>`; no heading on the sign-in form | `<title>{SITE_NAME}</title>` on every page, `<h1>{SITE_NAME}</h1>` on the sign-in form, from `lib/site.ts` | The product's name has to live somewhere, once: it is the rebrand's seam |
| `pages/api/health.ts` | — | a read-only health check | The deploy's smoke and the bootstrap's probe (design §5) |
| `jsconfig.json`, `next.config.js` | JS config | `tsconfig.json` (`allowJs`, the same `~/*` paths), `next.config.ts`, `eslint.config.mjs` | The monorepo's typecheck and lint; the build reads the project from `wrangler.jsonc` |
| `supabase/migrations`, `supabase/seed.sql` | `supabase db push`, `seed.sql` | `packages/db/src/migrations/010_init`, `020_auth_hook`, `030_seed`, byte for byte, applied by db-migrate | One runner and one ledger per project; the seed's `#public` is where the app sends a signed-in user |
| `supabase/config.toml` `[auth.hook.custom_access_token]` | `supabase config push` | `packages/db/src/auth-config.ts`, set by the runner after the migrations | Auth must not point at a function that does not exist yet (risk SL-B) |
| `supabase/config.toml` `enable_confirmations = true` | confirmation on | off until the project has SMTP (`authEmailConfirmation`) | A fresh project's built-in email reaches only its organization's members (risk SL-H) |
| `README.md`, "Deploy with Vercel" | a Vercel clone button | `orun new` | A product on Cloudflare does not offer its visitors that |

## SL0 — the spec

The repository's skeleton: `intent.yaml` (`ws_CHANGE_ME`; `dev` verify-only,
`stage`, `prod` promoted after stage; `github-pull-request`,
`github-push-main` and `local-development` bindings; stack-tectonic 0.19.0),
`ci.yml` as supabase-starter carries turso-starter's (`TU13`: the
manual-deploy contract — `workflow_dispatch` with `component`,
`environment` and `deploy_id`, the `run-name`, the dispatch planned as a
push to main, main only), `tag.yml`, the root manifests, `tooling/tsconfig`
and `tooling/eslint`, the discovery roots, the epic and the task contracts.

## SL1 — the chat app on Workers

`apps/web` as above, built by OpenNext into one Worker + Static Assets:
`next.config.ts` reads `NEXT_PUBLIC_SUPABASE_URL` and `_PUBLISHABLE_KEY`
from `wrangler.jsonc` for `next build` (production builds only — `next dev`
reads `.env.local`, as upstream); `wrangler.jsonc` is committed as the
fixture render of `wrangler.template.jsonc` (`pnpm run wire:fixture`).
`/api/health` asks Auth's `/auth/v1/settings` and the Data API's `channels`
with the publishable key and answers `{ok, auth, signup,
emailConfirmation, schema}` — 200 only when both answer, 503 with
`schema: "not migrated"` before the migrations. `tests/web`: the health
check (both answers, a refused key, no config, an unreachable project), the
data layer against a stand-in client, the Next config, the committed
wrangler config.

## SL2 — the Supabase project and the schema

- `infra/terraform/supabase`: supabase-starter's root, named for this
  repository, publishing `WIRING_SUPABASE`, `SUPABASE_PROJECT_REF`,
  `SUPABASE_DB_PASSWORD` and `SUPABASE_DB_URL`. The service-role key is not
  an output.
- `packages/db` (`@saas/db`, the name the db-migrate composition builds):
  the runner, `000_control`, upstream's three SQL files — checksums
  `aa334acd…` (`010_init`), `4da15071…` (`020_auth_hook`), `4786f8af…`
  (`030_seed`) — and `auth-config.ts`. `apply` applies what the ledger does
  not hold, then `configureAuth`: `PATCH /v1/projects/{ref}/config/auth`
  with `hook_custom_access_token_enabled: true` and
  `hook_custom_access_token_uri:
  pg-functions://postgres/public/custom_access_token_hook`, then a `GET`
  that must read both back. Its output carries
  `auth: {configured: [...]}`; a `plan` touches no Auth and says
  `auth: {pending: [...]}`.
- `infra/db-migrate`: per environment, `dependsOn: supabase` enforced on
  main and advisory on a pull request, its four secrets `secretEnv`
  (fail-closed).
- `tests/db` (18 tests, PGlite with Supabase's roles, `auth` schema,
  `extensions.uuid_generate_v4` and the publication stood in): the five
  tables under RLS, the roles trigger, the seed, the hook's claims for each
  role and its grants (denied to `anon` and `authenticated`), nothing for
  `anon`, member, moderator and admin permissions, the publication and
  `replica identity full`, upstream's checksums, and the Auth config.

## SL3 — ready to instantiate

The README (the upstream example first, the mapping to Vercel and
Supabase, how to run, test, preview and deploy) and this status.

## SL4 — a baseline

In supabase-starter's current shape (`SS10`), with db-migrate between the
project and the app:

- `blueprint.yaml` (requires github, cloudflare, supabase; subdomain from
  the Cloudflare connection; no domain asked; four brokered secrets; 14
  minutes) and `repo-blueprint.yaml` (`01-product`, 13 minutes; `02-docs`,
  1). No await but the convergence watch and the probe: every key the apply
  publishes is read fail-closed in the convergence (`testing/phases.test.sh`
  holds it key by key).
- `.baseline/`: the identity, the product's README (with "Deploy by hand",
  "Roles", "Your first migration", "Email", "Custom domain") and AGENTS.md,
  the two task contracts.
- The rebrand (the `SITE_NAME` seam; migrations never rewritten; the
  example's home protected), the bootstrap helpers, the deployment record
  (sign-up, roles and whether the schema is in place, read from
  `/api/health`), the context pack, the generated component docs.
- The tiers: contract tests, the blueprint read by orun v2.88.0, the leak
  gate, the offline bootstrap and the product's plans
  (`supabase → db-migrate → web`, enforced; advisory on a pull request), and
  the e2e: the landing's own checks; db-migrate's own steps against the
  stand-in, which now runs the configured hook; the web lane in its staged
  job tree with the stage wiring inlined; the smoke refused before the
  migrations and passing after; and the chat as a member, a moderator and an
  admin — roles in their sessions, the starter channels with authors, a
  message posted and read back, deletes allowed and refused by role, a
  channel added and removed, nothing for the bare publishable key, the
  publication.

Not proven live: risk SL-A.
