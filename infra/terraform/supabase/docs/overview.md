# supabase

Provisions Supabase projects for stage and prod, points their Auth at the chat, and wires the URL and key into orun secrets

Terraform-managed infrastructure, planned and applied per environment by its CI lane.

|              |                                                                                                      |
| ------------ | ---------------------------------------------------------------------------------------------------- |
| Type         | `terraform`                                                                                          |
| Source       | `infra/terraform/supabase`                                                                           |
| Environments | `stage`: `plan-only`, `apply` on a push to `main` · `prod`: `plan-only`, `apply` on a push to `main` |

## Depends on

- (none)

## Depended on by

- **db-migrate** — Applies the chat schema (packages/db's migrations) to the stage and prod Supabase projects, then switches on the access-token hook it needs
- **web** — The team chat (Next.js on Cloudflare Workers + Static Assets via @opennextjs/cloudflare, per environment)
