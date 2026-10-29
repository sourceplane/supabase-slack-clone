# db-tests

The migrations' tests (the manifest, upstream's three SQL files byte for byte, the Auth config the runner sets, and the schema they leave on a Supabase-shaped Postgres in process — the roles trigger, the access-token hook, row-level security by role and the Realtime publication)

The test suite for **db**. It deploys nothing: its lane installs, builds and runs the tests.

|              |                      |
| ------------ | -------------------- |
| Type         | `turbo-package`      |
| Source       | `tests/db`           |
| Package      | `@app/db-tests`      |
| Environments | `dev`: `quick-check` |

## Depends on

- (none)

## Depended on by

- (none)
