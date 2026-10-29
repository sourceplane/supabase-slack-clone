# supabase-slack-clone — risks and open questions

## SL-A — Unproven against a real organization (OPEN)

No Terraform apply, migration, live deploy or live bootstrap has run against
a real Supabase organization. Everything short of the platform is proven
offline in Baseline CI against a local stand-in: the Terraform root is held
to `fmt`, `init -backend=false` and `validate`; db-migrate's own lane steps
apply the schema to a Postgres with Supabase's roles; the built Worker is
served and the chat driven against it. What only a live run can say: whether
the brokered `management-access` token reaches the project's API keys and
Auth config (the supabase root's `supabase_settings` and the runner's
`PATCH config/auth` use the same grant), whether upstream's `010_init` — run
through the Management API as `postgres` — may drop and re-create the
`supabase_realtime` publication on a new project, and the wall-clock.
**Closes** with one bootstrap from the tag against a workspace with a
Supabase connection.

## SL-B — Who switches the access-token hook on (RESOLVED)

Upstream sets it in `supabase/config.toml` and pushes it with the CLI. The
supabase root could set it (`supabase_settings.auth`, provider 1.5.1), but
it applies before the migrations, so a first apply would point Auth at a
function that does not exist yet and break every sign-in until db-migrate
ran. The runner sets it after the migrations instead, every apply, and
reads it back (`packages/db/src/auth-config.ts`, `configureAuth`). Proved
offline: the stand-in's Auth runs the configured hook as
`supabase_auth_admin`, the e2e's three sign-ups carry `null`, `moderator`
and `admin` in `user_role`, and a second apply applies nothing and
re-asserts the hook. See design §4.

## SL-C — Anyone can sign up as an admin (ACCEPTED, documented)

Upstream's `handle_new_user` grants `admin` to any address containing
`+supaadmin@` and `moderator` to any containing `+supamod@`. That is the
example's demo, and the port keeps it — the e2e signs its moderator and
admin up that way. The product's README ("Roles"), AGENTS.md and the
operating contract tell the owner to replace the trigger in a migration and
grant roles in `public.user_roles` before real users arrive.

## SL-D — `public.create_user` is callable through the Data API (ACCEPTED, documented)

Upstream's seed helper is a `security definer` function in `public` that
inserts into `auth.users`. A Supabase project grants `execute` on new
functions in `public` to `anon` and `authenticated`, so it is reachable as
`/rest/v1/rpc/create_user`. The user it makes has no password and cannot
sign in; the addresses it can create could equally be signed up directly
(SL-C). Kept as upstream ships it; the replacement migration SL-C calls for
should revoke it too.

## SL-E — Where the publishable key lives (RESOLVED)

A wrangler `var`, rendered from the wiring document, not a Worker secret,
and inlined into the bundle by `next build`. It is shipped to every browser
by design; row-level security is the boundary. No service-role key is read
from the project or published: nothing in the product runs with it.

## SL-F — `NEXT_PUBLIC_*` are inlined at build time (RESOLVED)

`next build` inlines them into the browser bundle and the Worker's server
code alike. So every production build reads the two values from
`wrangler.jsonc` (`next.config.ts`): the verify lanes inline the committed
fixture's placeholder project, which nothing calls, and each deploy lane
re-renders the config from its environment's wiring document first. The e2e
builds with the stand-in's wiring and checks the bundle names it and not
the fixture.

## SL-G — The pages router on Next 16 and OpenNext (WATCH)

The example predates the app router. Next 16 still builds the pages router
(under Turbopack) and OpenNext 1.20 serves it; two calls the example made no
longer work and are fixed (IMPLEMENTATION-STATUS). A later Next that drops
the pages router, or an OpenNext that stops serving it, would need a port
of three pages.

## SL-H — Email confirmation (ACCEPTED)

Upstream's `config.toml` asks for confirmation. A fresh project's built-in
email reaches only its organization's members, so the supabase root creates
each project with confirmation off and sign-up works for anyone on the first
deploy; the owner turns it on with SMTP (`authEmailConfirmation`).

## SL-I — Realtime is not exercised offline (ACCEPTED)

The stand-in has no Realtime server. What Realtime streams is what the
`supabase_realtime` publication carries, and the e2e and `tests/db` assert
the three tables are in it with `replica identity full`. The browser's
websocket goes to Supabase directly; nothing on the Worker relays it.

## SL-J — The stack-tectonic pin (SETTLED)

0.19.0, as supabase-starter: 0.20.0's lane-scoped install links each job's
`node_modules` out of its tree, which Next 16's Turbopack refuses.
