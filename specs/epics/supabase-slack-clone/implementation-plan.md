# supabase-slack-clone — implementation plan

Five milestones, one pull request each, squash-merged once CI is green on
the head commit. Task keys: SL0 → SL-1 … SL4 → SL-5 (`tasks/`).

## SL0 — the spec (SL-1)

The repository's skeleton and its plan: `intent.yaml` (`ws_CHANGE_ME`, `dev`
verify-only, `stage`, `prod` with `promotion.dependsOn: stage`, the three
trigger bindings, stack-tectonic 0.19.0), `ci.yml` (turso-starter's, by way
of supabase-starter's copy: the manual-deploy contract included), `tag.yml`,
the root manifests, `tooling/tsconfig` and `tooling/eslint`, the four
discovery roots, this doc set and the task contracts.

**Done when** `orun validate` accepts the intent and `ci.yml` plans nothing
on the placeholder workspace.

## SL1 — the chat app on Workers (SL-2)

`apps/web` from the example at `9eaae4c`: pages, components, styles,
`lib/Store.js`, `lib/UserContext.js`, `public/`, Tailwind and Sass — then
only what the platform forces:

- `next` pinned at 16.3.8 (upstream: `latest`), React 19, and the two calls
  that no longer work: `<Link>` wrapping an `<a>` (Next ≥ 13 renders the
  anchor itself) and `onAuthStateChange`'s return shape (supabase-js 2 nests
  the subscription under `data`);
- the App component named `ChatApp` (upstream's name spells this
  repository's slug, which a product must not carry);
- `lib/site.ts` (`SITE_NAME`), read by every page's `<title>` and a heading
  on the sign-in page — the seam the rebrand rewrites;
- OpenNext: `next.config.ts` (reads the project from `wrangler.jsonc` for
  the build), `open-next.config.ts`, `wrangler.template.jsonc` →
  `wrangler.jsonc` committed as the fixture render, `tooling/wire`;
- `pages/api/health.ts` (design §5);
- `tests/web`: the health check, the data layer against a stand-in client,
  the Next config, the committed wrangler config.

**Done when** typecheck, lint, test and build are green and the build
inlines the project the wrangler config names.

## SL2 — the Supabase project and the schema (SL-3)

- `infra/terraform/supabase`: supabase-starter's root, renamed; its outputs
  `WIRING_SUPABASE` and the three database credentials, no service-role key.
- `packages/db` (`@saas/db`): the db-migrate composition's runner, its
  manifest checker (`tooling/migrations`), `000_control`, and upstream's
  `20240214102356_init.sql`, `20240214114147_auth-hook.sql` and `seed.sql`
  as `010_init`, `020_auth_hook`, `030_seed` — byte for byte, their
  checksums in `manifest.ts` and pinned again in `tests/db`.
- `auth-config.ts` and the runner's `configureAuth` (design §4).
- `infra/db-migrate`: `dependsOn: supabase` enforced on main, its secrets
  per environment, fail-closed.
- `apps/web/component.yaml`: `dependsOn: supabase` and `db-migrate`.
- `tests/db`: every migration on PGlite with Supabase's roles, `auth`
  schema and publication stood in — the tables under RLS, the roles trigger,
  the hook's claims and grants, every policy by role, the publication and
  its replica identity, the Auth config the runner writes.

**Done when** the root is valid, the migrations apply in process and every
role's permissions hold.

## SL3 — ready to instantiate (SL-4)

The README (opening with the example, the mapping to Vercel and Supabase,
how to run, test, preview and deploy) and `IMPLEMENTATION-STATUS.md` with
every departure.

## SL4 — a baseline (SL-5)

In supabase-starter's current shape (`SS10`): `blueprint.yaml` and
`repo-blueprint.yaml` (two phases, `01-product` and `02-docs`; one
`secrets` reconcile per provider; the task set-up in the background;
landings checked in the box; the watch at 5 s; no await but the watch and
the probe, because every published key is read fail-closed in the
convergence), `.baseline/` (identity, the product's README and AGENTS.md,
the task contracts), the rebrand, the bootstrap helpers, the deployment
record, the context pack, generated component docs, `BOOTSTRAP.md`,
`docs/phases/`, and the tiers in `baseline.yml`: the contract tests, the
leak gate, the offline bootstrap and the product's own plans, and the e2e —
db-migrate's own lane steps against a Supabase stand-in that runs the hook,
the web lane's steps in a staged job tree, the smoke refused before the
migrations and passing after, and the chat driven as three roles.

**Done when** Baseline CI is green on the PR's head commit and `baseline-v1`
is cut from the merge.
