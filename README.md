# supabase-slack-clone

Supabase's [Slack clone](https://github.com/supabase/supabase/tree/master/examples/slack-clone/nextjs-slack-clone)
— the Next.js example of a realtime team chat: channels, messages that
arrive live over Supabase Realtime, email and password sign-up through
Supabase Auth, and members, moderators and admins whose role rides in every
session through an Auth hook and is enforced by row-level security — on its
way to **Cloudflare Workers + Static Assets** through
[`@opennextjs/cloudflare`](https://opennext.js.org/cloudflare), with the
Supabase project provisioned by Terraform and its schema applied by
migrations through [Orun](https://github.com/sourceplane/orun), and then an
**Orun baseline**.

Being built, one pull request per milestone. The plan, the design and the
as-built status are in
[`specs/epics/supabase-slack-clone`](specs/epics/supabase-slack-clone/README.md).

| Milestone | What it lands |
|---|---|
| SL0 — the spec | intent, CI, tooling, this doc set and the task contracts |
| SL1 — the chat app on Workers | `apps/web` built by OpenNext, `tests/web` |
| SL2 — the Supabase project and the schema | `infra/terraform/supabase`, `packages/db`, `infra/db-migrate`, `tests/db` |
| SL3 — ready to instantiate | the README, the as-built status |
| SL4 — a baseline | the card, the build document, the bootstrap, the tests |

## Licence and credit

The app will be Supabase's [Slack clone example](https://github.com/supabase/supabase/tree/master/examples/slack-clone/nextjs-slack-clone),
by [Supabase](https://supabase.com). Its own `package.json` says MIT; the
[supabase/supabase](https://github.com/supabase/supabase) repository it lives
in is licensed under the Apache License 2.0, which `apps/web/LICENSE` will
carry.
