# web

The team chat (Next.js on Cloudflare Workers + Static Assets via @opennextjs/cloudflare, per environment)

A Cloudflare Worker with Static Assets (server rendering plus static files), deployed per environment by its CI lane.

|              |                                                                                                                    |
| ------------ | ------------------------------------------------------------------------------------------------------------------ |
| Type         | `cloudflare-workers-assets-turbo`                                                                                  |
| Source       | `apps/web`                                                                                                         |
| Package      | `@app/web`                                                                                                         |
| Environments | `dev`: `verify` · `stage`: `verify`, `deploy` on a push to `main` · `prod`: `verify`, `deploy` on a push to `main` |

## Depends on

- **supabase** — Provisions Supabase projects for stage and prod, points their Auth at the chat, and wires the URL and key into orun secrets
- **db-migrate** — Applies the chat schema (packages/db's migrations) to the stage and prod Supabase projects, then switches on the access-token hook it needs

## Depended on by

- (none)
