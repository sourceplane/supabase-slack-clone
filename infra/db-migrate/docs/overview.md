# db-migrate

Applies the chat schema (packages/db's migrations) to the stage and prod Supabase projects, then switches on the access-token hook it needs

Applies this repository's ordered database migrations per environment: plan on pull requests, apply on merge to `main`.

|              |                                                                                            |
| ------------ | ------------------------------------------------------------------------------------------ |
| Type         | `db-migrate`                                                                               |
| Source       | `infra/db-migrate`                                                                         |
| Environments | `stage`: `plan`, `apply` on a push to `main` · `prod`: `plan`, `apply` on a push to `main` |

## Depends on

- **db** — The schema as migrations, and the runner that applies them over the Supabase Management API (built by the db-migrate component before it plans or applies)
- **supabase** — Provisions Supabase projects for stage and prod, points their Auth at the chat, and wires the URL and key into orun secrets

## Depended on by

- **web** — The team chat (Next.js on Cloudflare Workers + Static Assets via @opennextjs/cloudflare, per environment)
