# supabase-slack-clone — open risks

What is not yet proven or not yet decided. The full write-up of every risk,
including the accepted and resolved ones, is
`specs/epics/supabase-slack-clone/risks-and-open-questions.md`; this page
lists only what is still live, so it should be short.

| ID | Risk | State | What closes it |
|---|---|---|---|
| SL-A | Unproven against a real organization: no Terraform apply, migration, live deploy or live bootstrap yet — so whether the brokered Supabase token reaches the API-keys and Auth-config endpoints, whether upstream's `010_init` may re-create the `supabase_realtime` publication through the Management API, and the wall-clock are all unknown | OPEN | One bootstrap from a tag against a workspace with a Supabase connection |
| SL-C | Upstream's plus-address roles let anyone sign up as an admin | ACCEPTED (documented for the product's owner) | A product's own migration that replaces the trigger |
| SL-D | Upstream's `public.create_user` seed helper is callable through the Data API | ACCEPTED (documented) | The same migration revokes it |
| SL-G | The pages router on Next 16 and OpenNext 1.20 | WATCH | Holds while both serve it |
