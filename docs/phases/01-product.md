# 01-product — the product, in one landing

The whole product lands as ONE pull request, and ONE convergence on main
provisions, migrates and deploys it on stage and prod: the Supabase project,
its Auth pointed at the app; the chat schema and the access-token hook; and
then the app — in that order, per environment.

**Budget: 13 minutes** (`expectedMinutes`, an estimate until a bootstrap is
timed): the landing checked in the box and merged in about a minute, then
the Supabase project's five to seven minutes, a minute of migrations, and
the app's build, deploy and smoke — stage and prod side by side.

**Places** every module `repo-blueprint.yaml` declares: the root manifests,
the product's README and `AGENTS.md` (where a coding agent starts), CI,
tooling and identity; `infra/terraform/supabase`; `packages/db` and
`infra/db-migrate`; `apps/web`; and `tests/web` and `tests/db`.
`testing/phases.test.sh` holds the set.

**Requires** three live connections, probed and waited for (up to ten
minutes, so a consent can be clicked while it waits): the GitHub App on the
account that OWNS the repository — the platform sees a PR only through that
installation — and Cloudflare and Supabase, which every credential below is
minted from. The Supabase organization needs room for **two** projects,
`<reponame>-stage` and `<reponame>-prod` — the free plan's limit.

## How one convergence keeps the order

| what has to come first | how the plan holds it |
|---|---|
| the Supabase project before the migrations | `db-migrate` reads the project's ref and database credentials (`SUPABASE_PROJECT_REF`, `SUPABASE_DB_PASSWORD`, `SUPABASE_DB_URL`, which the `supabase` apply lease-publishes) as `secretEnv` — fail-closed — and declares `dependsOn: supabase`, `mode: enforced` on main. A job resolves its secrets when it STARTS, so they are there |
| the migrations before the app | `web` declares `dependsOn: db-migrate` (and `supabase`), `mode: enforced` on main: the browser reads the tables the migrations create, and signs in through the hook they make |
| the hook's function before Auth points at it | the runner switches the access-token hook on in the project's Auth config only after the migrations that create `public.custom_access_token_hook` (`packages/db/src/auth-config.ts`) |
| the project's Auth before anyone signs up | the supabase apply sets the project's Site URL and redirect allow-list to the Worker and turns email confirmation off, after the project reports healthy |
| stage before prod | deferred during the bootstrap (below), so both environments run their chains side by side |

Every edge is **advisory on a pull request**, which applies and deploys
nothing. `testing/placement.test.sh` plans the placed product's own push to
main and reads the order off it: `supabase → db-migrate → web`.

## What runs

The run's task set-up — the epic, both milestones, both tasks — runs in the
background from the start (`background: true`), so every hook up to `task`
runs beside it; `task` is the first that waits for it.

| hook | what it does |
|---|---|
| `retouch` | one trailing `# orun: redeploy 01-product <stamp>` line in each component `.baseline/tasks/01-product.TaskContract.yaml` names (supabase, db-migrate, web), so a RE-RUN has a diff to land |
| `git-init`, `stage` | the tree becomes a git repository with a populated index (the rebrand enumerates `git ls-files`) |
| `rebrand` | renames the baseline's identity to the product's: the slug (intent, worker, secret project, the `repo` the Supabase project is named after), the name seam, the domain, the workers.dev subdomain (the Worker's URL and the project's Auth Site URL). The upstream template's own links are left alone |
| `orun-workspace` | writes the product's workspace into `intent.yaml` |
| `work-tree` | strips this repository's `work:` block from the product's intent |
| `promotion`, `dev-lanes` | defer prod's wait on stage and dev's push lanes until `02-docs` |
| `restage`, `rebrand-verify` | the sweep: no baseline identity left |
| `repo` | `orun.repo/ensure@v1`: creates (or finds) `<githuborg>/<reponame>` |
| `link` | the repository becomes the workspace's (`orun cloud link`, best effort; `orun cloud check` is the gate). Every convergence lane authenticates over GitHub OIDC through that link |
| `secrets-cloudflare` | `orun.integrations/reconcile@v1`, Cloudflare's two keys in one hook, each under its own scope, created side by side: `CLOUDFLARE_API_TOKEN` (workers-deploy, the app's deploy) and `CLOUDFLARE_ACCOUNT_ID` (account-id). Keys that exist are kept |
| `secrets-supabase` | the same for Supabase's two: `SUPABASE_ACCESS_TOKEN` (management-access: the project, its API keys, its Auth settings, the migrations and the hook) and `SUPABASE_ORG_ID` (org-id) |
| `task` | finds the phase's task and yields its key — waiting, if it must, for the background set-up |
| `land` | one PR bound to the task, its commit checked in the box first (`checks: local`: `orun validate`, then `orun plan` as the PR and as the merge would plan it, under a second); merged without waiting for the PR's CI (`plan` alone on a bootstrap branch); labelled `Product` in the build panel |
| `converge` (await) | `orun.run/watch@v1` on the merge commit's run, read every 5 s; resumes it up to three times |
| `verify` (await) | `orun.http/probe@v1`: `/` and `/api/health` on both workers.dev URLs |

## What the convergence does, per environment

1. **supabase** — `terraform apply`: one project, `<reponame>-<env>`, in the
   org `SUPABASE_ORG_ID` names, with a generated database password; then,
   once the project reports `ACTIVE_HEALTHY`, its API keys are read and its
   Auth is set — Site URL and redirect allow-list
   `https://<reponame>-web-<env>.<subdomain>.workers.dev` (or the
   environment's `SITE_URL`), email confirmation off. Its outputs are lease-published as `WIRING_SUPABASE`
   (the URL and the publishable key), `SUPABASE_PROJECT_REF`,
   `SUPABASE_DB_PASSWORD` and `SUPABASE_DB_URL`. A new project takes five to
   seven minutes to come up.
2. **db-migrate** — installs, builds `@saas/db`, and applies every migration
   the project's ledger (`_migrations.applied`) does not hold, through the
   Management API's query endpoint, each checked against its manifest
   checksum: `000_control`, then upstream's `010_init` (the tables, the
   roles, the policies, the Realtime publication), `020_auth_hook` and
   `030_seed` (`#public`, `#random`). Then it switches the access-token hook
   on in the project's Auth config and reads it back. A re-run applies
   nothing and re-asserts the hook.
3. **web** — installs, re-renders `wrangler.jsonc` from this environment's
   wiring document, builds with OpenNext (`next build` inlines the same URL
   and key into the browser bundle), deploys `<reponame>-web-<env>`, and
   smoke-tests it: the sign-in page, and `/api/health`, which answers only
   when the project's Auth answers the key the build inlined and its Data
   API knows the `channels` table.

No SMTP server is in it: sign-up works without one, because confirmation is
off. The owner turns it on later (the product's README, "Email").

## Verify / done means

- The convergence for the merge commit is green on stage and prod — in it,
  db-migrate resolved the three database credentials and the app's deploy
  resolved `WIRING_SUPABASE`, from stage and prod, where every later run
  reads them, and each fails without them, so there is no separate check
  that they exist.
- `/` and `/api/health` answer on both workers.dev URLs — the health check
  only once the schema is in place.

## Failure modes

| symptom | meaning → fix |
|---|---|
| parks on the `providers` probe | a connection is missing — GitHub on the repository's owner, Cloudflare, or Supabase. Connect it (console → Integrations); the probe is a wait, not a failure |
| supabase apply: project limit reached | the organization has no room for two more projects (the free plan allows two active ones). Pause or delete one, or upgrade, then re-run the phase |
| supabase apply: `does not support oauth access` | the provider is above 1.5.x, which reads billing endpoints an OAuth token cannot — `~> 1.5.1` is pinned for this reason |
| supabase apply: `Unable to read API keys` or `Unable to update auth settings` (401/403) | the Supabase connection's grant does not reach the project's API keys or its Auth configuration. Reconnect Supabase with a personal access token (console → Integrations → Supabase), or set the Site URL by hand and remove `supabase_settings` — then re-run |
| supabase apply: the project never reports `ACTIVE_HEALTHY` | the project is still coming up after ten minutes, or failed to. Its state is in the Supabase dashboard; re-run the phase once it is healthy (the project is adopted, not recreated) |
| supabase apply: project name already exists | `adopt.tf` looks the project up by name and imports it — if you removed that file, restore it |
| db-migrate: a missing `SUPABASE_DB_URL` (or ref, or password) before the first step | the supabase apply for that environment did not publish — read its log; db-migrate waits on it, so it shows as not run |
| db-migrate: `PATCH config/auth answered HTTP 401/403` | the Supabase grant reaches the query endpoint but not the project's Auth config. Reconnect Supabase with a personal access token and re-run; the applied migrations are not applied again |
| db-migrate: `checksum mismatch` | an applied migration was edited; restore it and make the change a new migration |
| web: `wire: missing wiring documents … WIRING_SUPABASE_<ENV>` | the supabase apply for that environment did not publish — read its log; web waits on it, so it shows as not run |
| `land`: `the landing's own check failed — orun plan for …` | the placed tree does not plan; the next line is orun's own error. Nothing was pushed. Fix it (or the baseline) and re-run the phase |
| `land` waits on CI after all | the product's repository requires a status check on `main` (branch protection or a ruleset), so GitHub refused the early merge; the landing waits for the check as a `checks: ci` landing would, then merges |
| web smoke: `/api/health` 503 | `schema: not migrated` — db-migrate did not run against this project; `auth: key refused` — the key the build inlined is not the project's (a stale wiring document); `auth: unreachable` — the project is paused or the URL is wrong |
| `build-app` fails: `Symlink apps/web/node_modules/next is invalid, it points out of the filesystem root` | the product's intent pins stack-tectonic ≥ 0.20.0 (lane-scoped install), which Next 16's Turbopack refuses. Pin 0.19.0 — `intent.yaml` says why |
| `verify-app-structure` fails: `test -f wrangler.jsonc` | `apps/web/wrangler.jsonc` is not committed. It must be: the check runs before the build, in a fresh checkout (`pnpm run wire:fixture` renders it) |
| the watch says green, the probe says 404 | another workflow ran on the push and the watch took its run. Only `ci.yml` may run on a push to main |
| re-run lands nothing | the hooks did not run (`--run-hooks`), or the contract names no component — `node tooling/bootstrap/retouch.mjs --check --affects .baseline/tasks/01-product.TaskContract.yaml` in the product's tree says which |

## Re-running

Idempotent: placement is additive, the rebrand is a no-op on branded files,
`git init` and the repo step are guarded, and the Supabase project is
adopted rather than recreated. A re-run of a phase whose PR already merged
lands the retouch markers alone, which re-plans exactly the components they
name. Once the tree is branded the phase derives as `drifted`, so `--resume`
leaves it alone; re-run it deliberately with `--phase 01-product` (or
`--redo 01-product`).

## What one convergence will run, before running it

From a placed product's tree:

```bash
node <baseline>/tooling/bootstrap/promotion.mjs --defer && node <baseline>/tooling/bootstrap/dev-lanes.mjs --defer
orun plan --intent intent.yaml --trigger github-push-main -v lanes
git checkout intent.yaml
```
