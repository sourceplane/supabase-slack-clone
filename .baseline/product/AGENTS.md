# supabase-slack-clone — notes for coding agents

You are in the repository of a live product. Read this before you change
anything; `README.md` is the same product told for the person who runs it.

## What this is

A team chat — channels, messages that arrive live, email and password
sign-up, and moderators and admins who can delete what members cannot — as a
Next.js app built by OpenNext into one Cloudflare Worker. The browser talks
to a Supabase project per environment (`stage`, `prod`) directly: Auth, the
Data API and Realtime, with the publishable key, and row-level security
decides what each user may read and write. Terraform creates the project;
db-migrate applies the chat schema to it and switches on the access-token
hook that puts each user's role in their session. Orun deploys it: a merge to
`main` converges what it changed — the Supabase project, then the schema,
then the app, stage before prod. `dev` only verifies.

| component | path | what it is |
|---|---|---|
| `web` | `apps/web` | the app and its Worker build (`component.yaml`, `next.config.ts`, `wrangler.template.jsonc`) |
| `supabase` | `infra/terraform/supabase` | the Supabase project per environment and its Auth settings |
| `db` | `packages/db` | the migrations, their manifest and the runner db-migrate calls |
| `db-migrate` | `infra/db-migrate` | applies `packages/db` to each environment's project |
| `db-tests` | `tests/db` | the schema's tests, on a Supabase-shaped Postgres in process |
| `web-tests` | `tests/web` | the app's vitest suite |

`intent.yaml` declares the environments, the workspace and how CI plans; each
`component.yaml` declares one component and what it depends on.

## Read first

1. `README.md` — what is where, running it locally, "Roles", "Your first
   migration", "Custom domain".
2. `ai/context/operations.md` — how a deploy works, the secrets model,
   row-level security and roles, the common operations.
3. `ai/context/deployment.md` — the live URLs, the workspace and the secrets,
   by name, as last probed.
4. `apps/web/lib/Store.js` — the Supabase client, the data hooks and the
   Realtime subscriptions every page uses.
5. `packages/db/src/migrations` and `packages/db/src/auth-config.ts` — the
   schema, its policies and the Auth hook the runner enables after them.

## How a change lands

- Work is tracked as tasks on the Orun workspace (`orun task list`). One task,
  one branch, one pull request against `main` — `orun pr open` names the
  branch after the task and records it in the pull request.
- Before you push: `pnpm install`, `pnpm run wire:fixture`, `pnpm typecheck`,
  `pnpm lint`, `pnpm test`, `pnpm build`. Nothing runs them for you: the pull
  request's `ci.yml` lanes build and dry-deploy the app, plan the Supabase
  root and the migrations, and type-check, lint and test nothing. `orun
  validate` and `orun plan` show what `ci.yml` will plan.
- Merging is deploying. Watch the run on `main`, then probe the URLs in
  `ai/context/deployment.md`: a run that planned nothing deployed nothing.
- A schema change is a NEW migration directory under
  `packages/db/src/migrations` plus its entry in `packages/db/src/manifest.ts`
  (`pnpm --filter @saas/db run manifest:fix` writes the checksum). A table in
  `public` gets row-level security and its policies in the migration that
  creates it — the publishable key is public by design. A table the chat
  should stream joins the `supabase_realtime` publication in a migration too.
- A new component is a directory under `apps/`, `infra/` or `packages/` with a
  `component.yaml`, declaring `dependsOn` on any infrastructure whose
  published secrets it reads.

## Do not touch

- `execution.state.workspace` in `intent.yaml`: every remote operation and
  every CI credential is scoped to it.
- An applied migration. db-migrate compares every file's sha256 with the
  manifest and with the database's own ledger, and refuses a changed one.
- `apps/web/wrangler.jsonc` by hand: edit `wrangler.template.jsonc` and run
  `pnpm run wire:fixture`. Never commit a real project's URL or key.
- `ai/context/deployment.md`, and the README between `<!-- 02-docs:begin -->`
  and `<!-- 02-docs:end -->`: both are rendered from probes.
- The Auth URLs and the access-token hook in the Supabase dashboard: the
  apply owns the Site URL, the redirect allow-list and `mailer_autoconfirm`,
  db-migrate owns the hook, and each undoes a dashboard edit on its next run.
- Secret values, anywhere — the repository, `ai/context/`, a log, GitHub.
  Provider credentials are brokered per run; secrets are inspected by name.
- `ci.yml` as the only workflow on a push to `main`: whatever watches a
  merge reads the newest run for its commit, and a second workflow there
  could be the run it reads.
- The last line of a `component.yaml` (`# orun: redeploy …`) is a deploy
  trigger; change it only to redeploy that component.
