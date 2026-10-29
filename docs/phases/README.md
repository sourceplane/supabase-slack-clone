# The phases — one blueprint, two selections, one landing that deploys

`repo-blueprint.yaml` declares two phases that take a product from
**nothing** to **live on stage and prod, documented**. Run them one at a time
with `--phase <name>`, or both unattended with `--resume`. There is no
umbrella workflow and no per-phase document: a phase is a selection on one
artifact, which is what makes running one alone, months later, from a fresh
container the same operation as running them all.

Each phase follows the same contract:

> **place its modules → brand them → check them in the box and land them as
> one pull request → watch the convergence that merge triggers
> (auto-resumed) → verify the outcome.**

The run's task set-up — the epic, a milestone per phase, a task per landing
— runs in the background from the start; the first hook that needs it, the
phase's `task`, waits for it.

Run from the baseline checkout (the blueprint's source is `path: .`); the
product's repository is wherever `--out` points.

## Execution order

| phase | minutes | lands | verified by |
|---|---|---|---|
| [`01-product`](01-product.md) | 13 | **the GitHub repo created**, then the WHOLE product in one PR: intent, CI, tooling, the Supabase Terraform root, the migrations, the app and their tests — one convergence provisions, migrates and deploys it in dependency order | convergence green (db-migrate resolving the database credentials and the app's deploy the `WIRING_SUPABASE` the apply published, each fail-closed); `/` and `/api/health` answer on both |
| [`02-docs`](02-docs.md) | 1 | the live-deployment record; the promotion gate and dev's lanes put back | committed manifest matches probed reality |

Fourteen minutes in all (`expectedMinutes` 13 + 1, the card's estimate) —
estimates until a bootstrap is timed.

**One landing builds the product.** The order the chat needs — the Supabase
project, then its schema, then the app that talks to both — is not a
sequence of landings. It is the components' own `dependsOn`, each edge
`mode: enforced` on a push to `main` and advisory on a pull request:

```
supabase ──▶ db-migrate ──▶ web        (per environment)
```

A job resolves its secrets when it starts, so db-migrate reads the project's
ref and database credentials the apply published, and the app's deploy
reads the wiring document: the project's URL and publishable key, rendered
into the Worker's vars and inlined into the browser bundle.
`testing/placement.test.sh` reads that order off the product's own
`orun plan --trigger github-push-main`. Each reads its keys from the place
every later run looks, and fails without them, so a green convergence
already says every published key is there — there is no separate check.

Every landing is a pull request on a branch named for its task
(`orun/BASE-<n>-<phase>`), checked before it is pushed: `orun validate`, then
`orun plan` as the pull request and as the merge would plan it, in the box,
in under a second (`checks: local`). Then it merges; nothing waits for the
PR's CI. On those branches `ci.yml` runs `plan` only and skips the lanes,
because the merge runs them on main a minute later, for real, and that
convergence is what the phase watches. The product carries no other
workflow. Its pull requests run `ci.yml`'s verify lanes — the app built and
dry-deployed per environment, the Supabase root planned, the migrations'
checksums verified offline — which type-check,
lint and test nothing; the baseline's own CI (Tier 2) installs, renders the
fixture, type-checks, lints, tests and builds this landing before a tag is
cut, and the product's README and `AGENTS.md` tell its developers to run
those steps before they push.

There is no custom-domain phase: the app answers on workers.dev. Attaching a
domain needs zone permissions the brokered `workers-deploy` token does not
carry, so it is an owner's step after the bootstrap (the product's README,
"Custom domain").

## What a phase says

The console's build panel shows a hook's `narrate:` verbatim as the build's
progress and a phase's `narrate.await` as what it is waiting on; from orun
v2.86 the engine's facts pin the repository, the epic, each pull request and
the live addresses beside them. So every line says one true thing about the
world, briefly, and no line asserts a state (`testing/phases.test.sh`):

- neither phase authors an `await` line: the engine says what a phase waits
  on — "<title>: <reason>" — which is also the line while `01-product`'s
  probe waits for a connection, and only the engine knows the reason;
- a line holds for every outcome its hook can have: the repository's says
  whether this build created it, a landing names its pull request or says
  there was nothing to land, a brokered key's holds whether it was minted now
  or kept;
- each landing carries a `label:` (`Product`, `Docs`), and `02-docs` has no
  re-probe — its render probes as it writes — so the panel gets the one set
  of addresses `01-product`'s probe filed.

## Inputs

`01-product` takes the product's identity once and writes it into the repo
(`.rebrand/values.json`); `02-docs` reads it back from the placed tree. But
the blueprint's **required** inputs — `reponame`, `productname`,
`githuborg` — are validated before any phase runs, so they must be supplied
on every invocation, single-phase ones included. A `--values` file is easier
than repeating `--set`.

- `productdomain` — NOT ASKED, default empty. The app goes live on
  workers.dev; empty brands the reserved placeholder `<reponame>.example.com`
  into `BASE_DOMAIN`, for an owner to replace when they attach a domain (the
  product's README, "Custom domain", which also sets `SITE_URL` so the
  Supabase project's Auth follows it). Pass it only for a
  product that already has its domain.

- `subdomain` — the workers.dev subdomain of the Cloudflare account you
  deploy into. It is in every URL the phases probe, and it is the origin the
  Supabase project's Auth sends its links to. A console or `--from bst_…`
  build reads it from the Cloudflare connection; pass it only for a hand-run
  build.
- `orunWorkspace` — workspace id (`ws_…`). Unset, it is the workspace the
  build runs in (`from: workspace`); with none anywhere, a placeholder that
  fails loudly rather than silently claiming another tenant's workspace.
- `epicSlug` (default `team-chat-baselining`) — the epic every phase
  clubs its task under. Found by slug, so a fresh run and a resumed run find
  the same work.
- `repoPrivate` (default `true`) — the repository's visibility at creation.

```bash
orun new --blueprint repo-blueprint.yaml \
  --out $HOME/products/acme-chat --run-hooks --phase 01-product \
  --values ~/acme-chat.values.yaml
```

Drop `--run-hooks` (or add `--status`) to preview. Without it a phase places
files and stops: no repo, no landing, no convergence watch, and no probe —
which is exactly what makes a dry instantiation of this baseline possible in
CI with no workspace and no provider (`testing/placement.test.sh`,
`testing/e2e.test.sh`).

## Email is not a phase

A fresh Supabase project emails only its organization's own members, so the
bootstrap creates each project with email confirmation off — sign-up signs a
user straight in, for anyone, from the first deploy — and asks for no SMTP
server. The owner turns confirmation on once a project has SMTP of its own
(the product's README, "Email"), and re-running `02-docs` records it.

## When a phase fails

- **Before it lands** (a probe that timed out, a rebrand residue, a refused
  link): nothing was merged. Fix what the message names and re-run the phase.
- **After it lands** (the convergence went red): the files are on main.
  `orun.run/watch@v1` has already resumed the run up to three times. Re-run
  the phase (`--phase 01-product`, `--redo 01-product` under `--resume`, or
  the console's Retry): its `retouch` hook gives the landing a diff and the
  components it names re-plan. The Supabase project is adopted rather than
  recreated (`adopt.tf`).
