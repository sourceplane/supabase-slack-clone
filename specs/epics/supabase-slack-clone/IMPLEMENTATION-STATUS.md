# supabase-slack-clone — implementation status (as built)

What shipped, milestone by milestone, kept apart from the plan. Upstream is
[supabase/supabase `examples/slack-clone/nextjs-slack-clone`](https://github.com/supabase/supabase/tree/master/examples/slack-clone/nextjs-slack-clone)
at `9eaae4cd2cf8e67f9aeadab044e9a14429331c13`.

| Milestone | Pull request | State |
|---|---|---|
| SL0 — the spec | [#1](https://github.com/sourceplane/supabase-slack-clone/pull/1) | in review |
| SL1 — the chat app on Workers | [#2](https://github.com/sourceplane/supabase-slack-clone/pull/2) | planned |
| SL2 — the Supabase project and the schema | [#3](https://github.com/sourceplane/supabase-slack-clone/pull/3) | planned |
| SL3 — ready to instantiate | [#4](https://github.com/sourceplane/supabase-slack-clone/pull/4) | planned |
| SL4 — a baseline | [#5](https://github.com/sourceplane/supabase-slack-clone/pull/5) | planned |

Nothing is built yet. Every departure from upstream is recorded here as
it lands.

## SL0 — the spec

The repository's skeleton: `intent.yaml` (`ws_CHANGE_ME`; `dev` verify-only,
`stage`, `prod` promoted after stage; `github-pull-request`,
`github-push-main` and `local-development` bindings; stack-tectonic 0.19.0),
`ci.yml` as supabase-starter carries turso-starter's (`TU13`: the
manual-deploy contract — `workflow_dispatch` with `component`,
`environment` and `deploy_id`, the `run-name`, the dispatch planned as a
push to main, main only), `tag.yml`, the root manifests, `tooling/tsconfig`
and `tooling/eslint`, the discovery roots, the epic and the task contracts.
