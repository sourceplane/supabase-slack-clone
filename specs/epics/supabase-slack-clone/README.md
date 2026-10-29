# Epic: supabase-slack-clone (SL)

**Supabase's Slack clone is a chat whose server does almost nothing. The browser signs in through Supabase Auth, reads and writes channels and messages through the Data API under row-level security, and streams them over Realtime — all with the publishable key. Its roles ride in the session: a custom access-token hook copies a user's role into their JWT, and the delete policies read it. None of that cares whether the pages come from a Vercel function or a Cloudflare Worker. The port keeps the code and moves what is Vercel's and the Supabase CLI's: where the app runs (an OpenNext Worker + Static Assets), where the project comes from (Terraform through Orun), how its schema arrives (db-migrate instead of `supabase db push`), and who switches the hook on (the migration runner instead of `supabase config push`).**

The upstream code stays the code: `lib/Store.js` (the client, the data hooks, the Realtime subscriptions), the pages, the components, the styles, the two migrations and the seed. The port adds the Workers build, the monorepo wrapper, `/api/health`, two test packages, the Terraform root, the migrations package and its runner, and the deploy contract that threads the project's URL and key into `next build` and into wrangler vars.

## Status

| Field | Value |
|-------|-------|
| Status | ✅ SL0–SL4 shipped (SL4 tagged `baseline-v1`). Supabase apply, migration and live deploy gated on a linked workspace; not yet proven by a live bootstrap (risk SL-A) |
| Cluster | **SL** (SL0–SL4) |
| Owner(s) | `apps/web` (the app) · `tests/web` · `infra/terraform/supabase` (the project) · `packages/db` + `infra/db-migrate` (the schema) · `tests/db` |
| Builds on | `supabase-starter` — the shape of the repository and of the baseline, the `supabase` Terraform root, the stand-in; `sveltekit-saas` — the db-migrate lane on a Supabase project |
| Upstream | [supabase/supabase `examples/slack-clone/nextjs-slack-clone`](https://github.com/supabase/supabase/tree/master/examples/slack-clone/nextjs-slack-clone), at `9eaae4cd2cf8e67f9aeadab044e9a14429331c13` |
| Licence | the example's `package.json` says MIT; the supabase/supabase repository is Apache-2.0, whose text `apps/web/LICENSE` carries |
| Decisions locked | (1) OpenNext on Workers + Static Assets, no Hyperdrive: nothing on the server opens a Postgres connection. (2) The publishable key is a wrangler var; no service-role key is published or read. (3) Upstream's migrations and seed are db-migrate migrations, byte for byte. (4) The access-token hook is set by the runner after the migrations, not by Terraform. (5) supabase → db-migrate → web, enforced on main, advisory on pull requests. (6) `/api/health` is read-only and answers only from the Worker. |
| Shipped as | `baseline-v1` (SL4) |

## Read order

1. `design.md` — what maps to what, the env/secret flow, the auth-hook decision, what is out of scope
2. `implementation-plan.md` — the milestones and what "done" means for each
3. `risks-and-open-questions.md` — what could go wrong and what was decided
4. `IMPLEMENTATION-STATUS.md` — what actually shipped (kept distinct from intent)

## Milestones at a glance

| Milestone | What it lands | Done when |
|---|---|---|
| SL0 — the spec | intent, CI, tooling, this doc set and the task contracts | merged on `main` |
| SL1 — the chat app on Workers | `apps/web` built by OpenNext, the rendered wrangler config, `/api/health`, `tests/web` | typecheck, lint, test and build green |
| SL2 — the Supabase project and the schema | `infra/terraform/supabase`, `packages/db`, `infra/db-migrate`, `tests/db`, the app's `dependsOn` | the root plans; the migrations apply on a Supabase-shaped Postgres and the hook gives each role its claim |
| SL3 — ready to instantiate | README, as-built status | a reader can run, test, preview and deploy it |
| SL4 — a baseline | card, build document, rename, bootstrap tooling, the product's README, AGENTS.md and context pack, tests | a new product goes from nothing to live on stage and prod in one landing; Baseline CI green |
