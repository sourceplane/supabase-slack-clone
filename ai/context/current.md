# supabase-slack-clone — where this repository stands

The entry page for anyone (or any agent) picking this repository up. It is
this repository's own state and does not ship to a product built from it; the
two pages that do are [operations.md](operations.md) and
[deployment.md](deployment.md).

## What it is

Supabase's Next.js Slack clone on Cloudflare Workers + Static Assets
(`@opennextjs/cloudflare`), its Supabase project per environment provisioned
by Terraform and its schema applied by db-migrate through Orun, packaged as
an Orun baseline: `orun new --blueprint repo-blueprint.yaml` builds a new
product in its own repository and takes it to live on stage and prod in one
landing (`01-product`: supabase → db-migrate → web per environment), then
records what went live (`02-docs`).

## Release

| | |
|---|---|
| Latest tag | `baseline-v1` (SL4) |
| Proven live | No. Nothing has been applied against a real Supabase organization: no Terraform apply, no migration, no live deploy, no live bootstrap (risk SL-A). Everything short of the platform is proven offline in Baseline CI, against a local Supabase stand-in |

## Where to read

| Question | Page |
|---|---|
| What shipped, and every departure from upstream | `specs/epics/supabase-slack-clone/IMPLEMENTATION-STATUS.md` |
| Why it is built this way | [decisions.md](decisions.md), then `specs/epics/supabase-slack-clone/design.md` |
| What could still go wrong | [open-risks.md](open-risks.md), then `specs/epics/supabase-slack-clone/risks-and-open-questions.md` |
| How to instantiate it | `BOOTSTRAP.md`, `docs/phases/` |
| What each component is | `apps/web/docs/`, `infra/terraform/supabase/docs/`, `infra/db-migrate/docs/`, `packages/db/docs/`, `tests/web/docs/`, `tests/db/docs/` (generated; `python3 tooling/catalog/gen-component-docs.py`) |

## Next

1. Bootstrap one product from `baseline-v1` against a workspace with a
   Supabase connection, and record its timings — the apply, the brokered
   token's reach to the API-keys and Auth-config endpoints, the migrations
   and the hook, a sign-up on the first deploy (closes SL-A).
2. Decide whether the baseline should replace upstream's plus-address roles
   (SL-C) instead of leaving it to each product's owner.
