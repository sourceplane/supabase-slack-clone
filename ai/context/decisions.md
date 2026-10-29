# supabase-slack-clone — decisions

The choices that shape this repository, one line each, with where the full
reasoning lives.

| # | Decision | Why | Source |
|---|---|---|---|
| 1 | OpenNext on Workers + Static Assets (`cloudflare-workers-assets-turbo`), no Hyperdrive | The example's every Supabase call runs in the browser over HTTPS; the Worker serves pages and one health check, and never opens a Postgres connection | `specs/epics/supabase-slack-clone/design.md` §2 |
| 2 | The publishable key is a wrangler var; no service-role key is published or read | It ships to every browser by design and row-level security is the boundary; nothing in the product runs with the service role | risk SL-E |
| 3 | `wrangler.jsonc` committed as the fixture render; stage and prod re-render it from `WIRING_SUPABASE_<ENV>` (`optionalSecretEnv`), and `next build` reads the project from it | The composition checks the file exists before the build; the bundle and the Worker must name one project; stage must not wait on prod's document | risk SL-F, supabase-starter |
| 4 | Upstream's two migrations and its seed are db-migrate migrations, byte for byte | One runner and one checksummed ledger per project, a pull request that verifies offline, and the `#public` channel the app sends everyone to | design §2 |
| 5 | The access-token hook is switched on by the migration runner after the migrations, every apply, and read back | Terraform applies before the migrations, so it would point Auth at a function that does not exist yet; SQL cannot set Auth config | design §4, risk SL-B |
| 6 | supabase → db-migrate → web, each edge enforced on a push to `main`, advisory on a pull request | One convergence provisions, migrates, then deploys per environment | `repo-blueprint.yaml`, `testing/placement.test.sh` |
| 7 | `/api/health` asks Auth's settings and the Data API's `channels` with the publishable key, read-only | A page that renders proves only that the Worker deployed; this proves the project is bound and migrated, and only the Worker can answer it | design §5 |
| 8 | `next` pinned at 16.3.8; the two calls Next 16 and supabase-js 2 refuse fixed; the App component renamed `ChatApp` | `latest` is not reproducible; upstream's `<Link><a>` and `onAuthStateChange` shape no longer work; upstream's component name spells this repository's slug | IMPLEMENTATION-STATUS |
| 9 | Email confirmation off until the project has SMTP of its own | A fresh project's built-in email reaches only its organization's members | risk SL-H |
| 10 | Upstream's plus-address roles kept, and documented as a demo to replace | Changing the example's role model is not the port's to decide; the product's README says how | risk SL-C |
| 11 | `packages/db` is named `@saas/db` | The db-migrate composition builds the package by that name | `infra/db-migrate`, stack-tectonic 0.19.0 |
| 12 | supabase-starter's current shape (`SS10`): two phases, one landing; one `secrets` reconcile per provider; the task set-up in the background; landings checked in the box; no authored await line; `AGENTS.md` in every product; `ci.yml` as turso-starter's with the manual-deploy contract | The reference starter's current `main` is the standard | `repo-blueprint.yaml`, `testing/phases.test.sh` |
| 13 | stack-tectonic 0.19.0, not 0.20.0 | 0.20.0's lane-scoped install is refused by Turbopack | `intent.yaml` |
| 14 | Component docs are generated from the manifests and checked in CI | A hand-written copy of the dependency graph, bindings and published outputs drifts silently | `tooling/catalog/gen-component-docs.py` |
