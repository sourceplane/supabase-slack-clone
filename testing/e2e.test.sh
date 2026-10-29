#!/usr/bin/env bash
# TIER 2 — the product a bootstrap produces builds, migrates, deploys (dry),
# serves, and chats: members, a moderator and an admin, through Supabase
# Auth, the Data API and the access-token hook.
#
# placement.test.sh proves the tree a bootstrap ends with is the right tree,
# and that its own plan converges in the right order. This proves it WORKS,
# by doing to it what its own pipelines will:
#
#   1. at the 01-product landing (the commit its PR merges), install with the
#      lockfile the product ships, render the wrangler fixture (which must
#      change nothing: the render is committed), typecheck, lint, test, build.
#      The landing itself is checked in the build box with `orun validate`
#      and `orun plan` alone (`checks: local`), its PR runs `plan` alone (an
#      `orun/BASE-*` branch), and a product's pull-request lanes run none of
#      these steps, so THIS is where a product those steps refuse is caught:
#      before the tag, not after a build has merged it;
#   2. a Supabase project of its own, stood in for: a Postgres on a random
#      port with Supabase's roles, its `auth` schema and the
#      `supabase_realtime` publication (testing/lib/local-postgres.sh), and
#      the endpoints this product calls on a project — Auth (GoTrue, which
#      runs the project's access-token hook when one is configured), the
#      Data API (PostgREST: filters, ordering, embedded authors, writes under
#      row-level security), and the Management API's query and Auth-config
#      endpoints the migration runner calls (testing/lib/fake-supabase-api.py);
#   3. the web lane's own steps for stage, rendered for a pull request (the
#      verify profile carries deploy-dry-run; the deploy profile does not) and
#      run in its staged job tree: install, `verify-app-structure` (the
#      committed wrangler.jsonc must exist BEFORE the build, in a tree with no
#      build output), `build-app` — which re-renders the config from the
#      stage wiring document it is handed, as the deploy does, and inlines
#      that project into the browser bundle — then `verify-build-output` and
#      `deploy-dry-run`;
#   4. the built Worker under `wrangler dev`, with NO .dev.vars, over a
#      project with NO schema yet: the component's OWN `smokeCommand`,
#      verbatim, must REFUSE it — /api/health says the schema is missing;
#   5. the db-migrate lane's own steps for stage, rendered for the push that
#      merges 01-product and run in its staged job tree: install, build
#      @saas/db, apply — upstream's three SQL files, verbatim, and then the
#      access-token hook switched on in the project's Auth config; applied
#      again: nothing, the hook re-asserted; and the pull request's offline
#      plan step;
#   6. the smoke again, now passing, and every route the product promises
#      under the product's own name; then the chat as the browser drives it:
#      a member, a moderator and an admin sign up with their roles in their
#      sessions, the two starter channels and their messages with authors, a
#      message posted and read back by somebody else, deletes allowed and
#      refused by role, a channel added and removed, nothing at all for the
#      bare publishable key, and the three tables in the Realtime publication
#      with full row images.
#
# WHAT IS ONLY OFFLINE HERE. The browser is not driven: the pages run their
# Supabase calls client-side, and those calls — supabase-js, from the
# product's own installed copy, with the same arguments lib/Store.js and
# pages/_app.js use — are made from Node (testing/lib/chat-client.mjs).
# Realtime's websocket is not stood in for: the publication it streams is
# asserted instead. Supabase is a stand-in, faithful to the requests the app
# and the runner make and no further. The platform's half — create the
# repository, mint the brokered tokens, create a real Supabase project, read
# its keys, set its Auth, migrate and deploy for real and probe workers.dev —
# is a bootstrap against a workspace (BOOTSTRAP.md); the Terraform root is
# validated below when terraform is on PATH, never applied.
#
# Needs: orun, node, pnpm, python3 (+PyYAML), git, curl, psql and a
# PostgreSQL server install (initdb, pg_ctl), and the network for
# `pnpm install` (or a warm store). A few minutes: three installs, two builds.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
# shellcheck source=lib/bootstrap.sh
source "$here/lib/bootstrap.sh"
# shellcheck source=lib/local-postgres.sh
source "$here/lib/local-postgres.sh"

for bin in orun node pnpm python3 git curl psql; do
  command -v "$bin" >/dev/null || { echo "e2e.test.sh needs $bin on PATH" >&2; exit 1; }
done
pg_bin >/dev/null || { echo "e2e.test.sh needs a PostgreSQL server install (initdb, pg_ctl)" >&2; exit 1; }

scratch="$(mktemp -d)"
pgdir="$(mktemp -d)"
dev_pid=""
api_pid=""
# wrangler dev runs under pnpm, node and two workerd processes; a TERM to the
# first does not reach the rest, and waiting on it then never returns. So each
# server is started as its own process group (setsid) and the group stopped.
stop_group() {
  local pid="$1"
  [ -n "$pid" ] || return 0
  kill -TERM -- "-$pid" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 -- "-$pid" 2>/dev/null || break; sleep 0.5; done
  kill -KILL -- "-$pid" 2>/dev/null || true
}
cleanup() {
  stop_group "$dev_pid"
  stop_group "$api_pid"
  pg_down "$pgdir"
  [ -n "$pgdir" ] && [ -d "$pgdir" ] && rm -rf "$pgdir"
  [ -n "$scratch" ] && [ -d "$scratch" ] && rm -rf "$scratch"
}
trap cleanup EXIT
free_port() { python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()"; }
values="$here/fixtures/acme.json"
repo="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['reponame'])" "$values")"
export CI=1 WRANGLER_SEND_METRICS=false NEXT_TELEMETRY_DISABLED=1 TURBO_TELEMETRY_DISABLED=1

# The landing's own checks, step for step — what the product's Checks
# workflow ran on a pull request before the product carried ci.yml alone —
# run here at once on the whole tree.
LANDING_CHECKS=(
  "pnpm install --frozen-lockfile"
  "pnpm run wire:fixture"
  "pnpm typecheck"
  "pnpm lint"
  "pnpm test"
  "pnpm build"
)
checks() { # DIR LOG
  local dir="$1" log="$2" cmd
  for cmd in "${LANDING_CHECKS[@]}"; do
    echo "   \$ $cmd" | tee -a "$log"
    if ! (cd "$dir" && bash -c "$cmd") >> "$log" 2>&1; then
      echo "FAIL: \`$cmd\` failed in $dir" >&2; tail -40 "$log" >&2; return 1
    fi
  done
}

# One job of a plan, written out as the runner would run it: each `run:` step
# (the `use:` actions are setup-node and setup-pnpm, which this machine has)
# as a numbered script, the job's env, and the component path the steps run
# in. Steps are picked BY ID when given, else every `run:` step in order.
extract_job() { # PLAN JOB-ID OUT-DIR [STEP-ID…]
  python3 - "$@" <<'PY'
import json, pathlib, sys
plan, jid, out, *want = sys.argv[1:]
job = next((j for j in json.load(open(plan))["jobs"] if j["id"] == jid), None)
if job is None:
    sys.exit(f"the plan has no job {jid}")
out = pathlib.Path(out); out.mkdir(parents=True)
steps = [s for s in job["steps"] if s.get("run")]
if want:
    by = {s["id"]: s for s in steps}
    missing = [w for w in want if w not in by]
    if missing:
        sys.exit(f"{jid} has no step(s) {missing}")
    steps = [by[w] for w in want]
for i, s in enumerate(steps):
    (out / f"{i:02d}.sh").write_text(s["run"])
    (out / f"{i:02d}.id").write_text(s["id"])
(out / "path").write_text(job.get("path") or ".")
with (out / "env").open("w") as f:
    for k, v in (job.get("env") or {}).items():
        f.write(f"export {k}={json.dumps(v)}\n")
PY
}
run_job() { # STEPS-DIR WORK-TREE ENV LOG-PREFIX
  local steps="$1" work="$2" envname="$3" logp="$4" s id
  for s in "$steps"/[0-9][0-9].sh; do
    id="$(cat "${s%.sh}.id")"
    echo "   ▸ $id"
    if ! (cd "$work/$(cat "$steps/path")" && source "$steps/env" && export ORUN_ENVIRONMENT="$envname" \
          && bash -e "$s") > "$logp-$id.log" 2>&1; then
      echo "FAIL: the lane's $id step" >&2; tail -40 "$logp-$id.log" >&2; return 1
    fi
  done
}

echo "── the offline bootstrap (testing/lib/bootstrap.sh)"
tree="$scratch/$repo"
bootstrap_offline "$root" "$tree" "$values" "$scratch/logs" > "$scratch/bootstrap.log" 2>&1 || {
  echo "FAIL: the offline bootstrap stopped" >&2; tail -40 "$scratch/bootstrap.log" >&2; exit 1; }
echo "   2 phases placed and landed"

# ── 1. the product's own pull request ──────────────────────────────────────
echo "── 01-product's landing: install, the fixture render, typecheck, lint, test, build"
s01="$(git -C "$tree" rev-parse HEAD~1)"
at01="$scratch/at-01/$repo"
git -C "$tree" worktree add -q "$at01" "$s01"
checks "$at01" "$scratch/checks.log"
dirty="$(git -C "$at01" status --porcelain)"
[ -z "$dirty" ] || { echo "FAIL: the checks changed tracked files — the committed wrangler.jsonc is not the fixture render:" >&2; echo "$dirty" >&2; exit 1; }
echo "   the checks left the tree as committed (wire:fixture rendered the committed wrangler.jsonc)"

# The Supabase root, as far as it goes without a cloud: formatted, and valid
# against the pinned providers its lock file names.
if command -v terraform >/dev/null; then
  echo "── the product's supabase root: terraform fmt, init -backend=false, validate"
  tfdir="$scratch/tf"
  cp -r "$tree/infra/terraform/supabase/terraform" "$tfdir"
  (cd "$tfdir" && terraform fmt -check -diff . && terraform init -backend=false -input=false \
     && terraform validate) > "$scratch/terraform.log" 2>&1 \
    || { echo "FAIL: the product's supabase root" >&2; tail -30 "$scratch/terraform.log" >&2; exit 1; }
  cmp -s "$tfdir/.terraform.lock.hcl" "$tree/infra/terraform/supabase/terraform/.terraform.lock.hcl" \
    || { echo "FAIL: terraform init changed the committed lock file" >&2; exit 1; }
  echo "   formatted and valid; the committed lock file is what init resolves"
else
  echo "── the product's supabase root: SKIPPED (no terraform on PATH)"
fi

# ── 2. a Supabase project, stood in for ────────────────────────────────────
echo "── a local Postgres with Supabase's roles, and the Supabase stand-in"
pgport="$(free_port)"
pgurl="$(pg_up "$pgdir" "$pgport")" || { echo "FAIL: Postgres did not start" >&2; exit 1; }
admin="postgres://supabase_admin@127.0.0.1:$pgport/postgres"
api_port="$(free_port)"
ref="localproject"
setsid python3 "$here/lib/fake-supabase-api.py" "$api_port" "$pgurl" --ref "$ref" --auth "$admin" \
  > "$scratch/api.log" 2>&1 < /dev/null &
api_pid=$!
for _ in $(seq 1 30); do grep -q '^anon-key ' "$scratch/api.log" 2>/dev/null && curl -s -o /dev/null "http://127.0.0.1:$api_port/" && break; sleep 0.3; done
anon="$(sed -n 's/^anon-key //p' "$scratch/api.log")"
[ -n "$anon" ] || { echo "FAIL: the Supabase stand-in did not start" >&2; cat "$scratch/api.log" >&2; exit 1; }
supabase_url="http://127.0.0.1:$api_port"
echo "   $pgurl; the project on $supabase_url (no migration yet)"

# The two plans the lanes below run from, each in the product's own tree: a
# push to main at the 01-product commit (the db-migrate lane's APPLY profile),
# and a pull request over the finished product against an empty base (the web
# lane's VERIFY profile, which carries deploy-dry-run, and db-migrate's PLAN).
(cd "$at01" && orun plan --intent intent.yaml --trigger github-push-main --env stage --output "$scratch/plan-main.json") > "$scratch/plan-main.log" 2>&1 \
  || { echo "FAIL: orun plan (push to main)" >&2; tail -15 "$scratch/plan-main.log" >&2; exit 1; }
git -C "$tree" worktree remove --force "$at01"
mkdir -p "$scratch/pr"
git clone -q "$tree" "$scratch/pr/$repo"
prtree="$scratch/pr/$repo"
git -C "$prtree" checkout -q --orphan empty
git -C "$prtree" rm -rqf .
git -C "$prtree" -c user.email=t@example.invalid -c user.name=t commit -qm empty --allow-empty
git -C "$prtree" checkout -q main
(cd "$prtree" && orun plan --intent intent.yaml --trigger github-pull-request --base empty --head HEAD --env stage \
   --output "$scratch/plan-pr.json") > "$scratch/plan-pr.log" 2>&1 \
  || { echo "FAIL: orun plan (pull request)" >&2; tail -15 "$scratch/plan-pr.log" >&2; exit 1; }
# This tier runs the bootstrap floor, newer than the orun the product's CI
# pins, and both read the per-edge `modeRules`: on a pull request — which
# applies and deploys nothing — the infrastructure edges that order a push to
# main are advisory, so no lane waits on another. (placement.test.sh checks
# the push to main's order.)
python3 - "$scratch/plan-pr.json" <<'PY'
import json, sys
jobs = {j["component"]: j for j in json.load(open(sys.argv[1]))["jobs"] if j["environment"] == "stage"}
chain = ["supabase", "db-migrate", "web"]
for a, b in zip(chain, chain[1:]):
    ja, jb = jobs[a], jobs[b]
    if ja["id"] in (jb.get("dependsOn") or []) or ja["id"] not in (jb.get("advisoryDependsOn") or []):
        sys.exit(f"FAIL: on a pull request {b}@stage must name {a}@stage as advisory, not wait on it")
print("   pull request: " + " → ".join(chain) + ", every edge advisory")
PY

# ── 3. the web lane's steps, for stage ─────────────────────────────────────
echo "── the stage web lane: install, verify-app-structure, build-app, verify-build-output, deploy-dry-run"
extract_job "$scratch/plan-pr.json" web.stage.verify-deploy "$scratch/steps-web" \
  install-workspace-dependencies verify-app-structure build-app verify-build-output deploy-dry-run
work="$prtree/.orun/runs/e2e/web.stage.verify-deploy/work"
# The job's private tree, staged as orun stages it — no build output, no
# node_modules: under stack-tectonic 0.19.0 the job installs inside it.
python3 "$here/lib/stage-job.py" "$prtree" "$work"
[ ! -e "$work/apps/web/.open-next" ] && [ -f "$work/apps/web/wrangler.jsonc" ] \
  || { echo "FAIL: the staged tree is not a fresh checkout with the committed wrangler.jsonc" >&2; exit 1; }
echo "   staged: $(realpath --relative-to="$prtree" "$work") — no build output, the committed wrangler.jsonc"
# The stage wiring document, as the supabase apply publishes it and the lane
# resolves it (optionalSecretEnv WIRING_SUPABASE_STAGE): the stand-in's URL
# and its anon key.
export WIRING_SUPABASE_STAGE="{\"supabase_url\":\"$supabase_url\",\"supabase_anon_key\":\"$anon\"}"
run_job "$scratch/steps-web" "$work" stage "$scratch/web"
unset WIRING_SUPABASE_STAGE
grep -q "\"NEXT_PUBLIC_SUPABASE_URL\": \"$supabase_url\"" "$work/apps/web/wrangler.jsonc" \
  || { echo "FAIL: build-app did not re-render wrangler.jsonc from the stage wiring document" >&2; exit 1; }
[ "$(node -e 'const fs=require("fs");process.stdout.write(String(fs.readdirSync(process.argv[1]).length))' "$work/node_modules")" -gt 0 ] && [ ! -L "$work/node_modules" ] \
  || { echo "FAIL: the job's install did not land inside its own tree" >&2; exit 1; }
# `next build` inlined the SAME project into the browser bundle — not the
# committed fixture's.
grep -rqF "$supabase_url" "$work/apps/web/.open-next/assets/_next/static" \
  && ! grep -rqF "stage-project-ref.supabase.co" "$work/apps/web/.open-next/assets/_next/static" \
  || { echo "FAIL: the browser bundle does not carry the project the stage wiring names" >&2; exit 1; }
echo "   the staged build ran inside its own tree; the Worker's vars and the browser bundle name the stage project it was handed"

# ── 4. serve it, over a project with no schema ─────────────────────────────
echo "── wrangler dev over the built Worker, before any migration"
[ ! -e "$work/apps/web/.dev.vars" ] || { echo "FAIL: the staged tree carries a .dev.vars" >&2; exit 1; }
port="$(free_port)"
(cd "$work/apps/web" && exec setsid pnpm exec wrangler dev --config wrangler.jsonc --ip 127.0.0.1 --port "$port" \
   --name "$repo-web-stage" --show-interactive-dev-session=false) > "$scratch/dev.log" 2>&1 < /dev/null &
dev_pid=$!
url="http://127.0.0.1:$port"
for _ in $(seq 1 90); do
  curl -s -o /dev/null "$url/" && break
  kill -0 "$dev_pid" 2>/dev/null || { echo "FAIL: wrangler dev exited" >&2; tail -30 "$scratch/dev.log" >&2; exit 1; }
  sleep 1
done
curl -s -o /dev/null "$url/" || { echo "FAIL: wrangler dev never answered" >&2; tail -30 "$scratch/dev.log" >&2; exit 1; }
smoke="$(python3 -c "import yaml,sys;print(yaml.safe_load(open(sys.argv[1]))['spec']['parameters']['smokeCommand'])" "$tree/apps/web/component.yaml")"
if DEPLOYED_URL="$url" bash -c "$smoke" > /dev/null 2>&1; then
  echo "FAIL: the deploy's smoke passed over a project with no schema — it proves nothing about the migrations" >&2; exit 1
fi
before="$(curl -s -w ' %{http_code}' "$url/api/health")"
[ "$before" = '{"ok":false,"auth":"reachable","signup":"open","emailConfirmation":"off","schema":"not migrated"} 503' ] \
  || { echo "FAIL: /api/health before the migrations answered $before" >&2; exit 1; }
echo "   the component's own smokeCommand refuses it: /api/health answers 503, schema not migrated"

# ── 5. the db-migrate lane, in its staged job tree ─────────────────────────
echo "── the stage db-migrate lane: install, build @saas/db, apply — then apply again, and the PR's plan"
extract_job "$scratch/plan-main.json" db-migrate.stage.migrate "$scratch/steps-migrate" \
  install-dependencies build-db-package "Migration Apply"
extract_job "$scratch/plan-main.json" db-migrate.stage.migrate "$scratch/steps-migrate-again" "Migration Apply"
extract_job "$scratch/plan-pr.json" db-migrate.stage.migrate "$scratch/steps-migrate-plan" "Migration Plan"
# Staged from the fresh clone (a CI checkout: no build output, no
# node_modules); its migrations are the 01-product commit's, byte for byte.
mwork="$prtree/.orun/runs/e2e/db-migrate.stage.migrate/work"
python3 "$here/lib/stage-job.py" "$prtree" "$mwork"
# The component's secretEnv, as the lane resolves it: the supabase apply's
# published credentials and the brokered access token. SUPABASE_API_URL is
# the one value no lane has — it points the runner at the stand-in.
export SUPABASE_ACCESS_TOKEN=e2e-token SUPABASE_PROJECT_REF="$ref" SUPABASE_DB_PASSWORD=postgres \
       SUPABASE_DB_URL="$pgurl" SUPABASE_API_URL="$supabase_url"
hook_config() { curl -s -H "authorization: Bearer e2e-token" "$supabase_url/v1/projects/$ref/config/auth" \
  | python3 -c 'import json,sys;c=json.load(sys.stdin);print(c.get("hook_custom_access_token_enabled"), c.get("hook_custom_access_token_uri"))'; }
[ "$(hook_config)" = "False None" ] || { echo "FAIL: the project's Auth has a hook before any migration: $(hook_config)" >&2; exit 1; }
run_job "$scratch/steps-migrate" "$mwork" stage "$scratch/migrate"
result() { python3 -c "import json,sys;t=open(sys.argv[1]).read();r=json.loads(t[t.index('{'):t.rindex('}')+1]);print(' '.join(r['applied']), '|', ','.join((r.get('auth') or {}).get('configured') or []))" "$1"; }
want="000_control_baseline 010_init 020_auth_hook 030_seed | hook_custom_access_token_enabled,hook_custom_access_token_uri"
[ "$(result "$scratch/migrate-Migration Apply.log")" = "$want" ] \
  || { echo "FAIL: the first apply did '$(result "$scratch/migrate-Migration Apply.log")', not '$want'" >&2; exit 1; }
[ "$(hook_config)" = "True pg-functions://postgres/public/custom_access_token_hook" ] \
  || { echo "FAIL: the apply did not switch the access-token hook on: $(hook_config)" >&2; exit 1; }
echo "   applied ${want%% |*}, then switched the access-token hook on"
run_job "$scratch/steps-migrate-again" "$mwork" stage "$scratch/migrate-again"
again="| hook_custom_access_token_enabled,hook_custom_access_token_uri"
[ "$(result "$scratch/migrate-again-Migration Apply.log")" = " $again" ] \
  || { echo "FAIL: a second apply did '$(result "$scratch/migrate-again-Migration Apply.log")'" >&2; exit 1; }
echo "   a second apply applied nothing and re-asserted the hook (the ledger holds $(psql "$pgurl" -XAtc 'select count(*) from _migrations.applied') migrations)"
run_job "$scratch/steps-migrate-plan" "$mwork" stage "$scratch/migrate-plan"
[ "$(result "$scratch/migrate-plan-Migration Plan.log")" = "${want%% |*} | " ] \
  || { echo "FAIL: the pull request's offline plan did '$(result "$scratch/migrate-plan-Migration Plan.log")'" >&2; exit 1; }
echo "   the pull request's plan step verifies every migration's checksum offline and touches no Auth"
unset SUPABASE_ACCESS_TOKEN SUPABASE_PROJECT_REF SUPABASE_DB_PASSWORD SUPABASE_DB_URL SUPABASE_API_URL
rm -rf "$mwork"

# ── 6. the product, migrated ───────────────────────────────────────────────
echo "── the migrated product"
echo "   ▸ the component's own smokeCommand, DEPLOYED_URL=$url"
DEPLOYED_URL="$url" bash -c "$smoke" || { echo "FAIL: the deploy's smoke refused the migrated product" >&2; tail -20 "$scratch/dev.log" >&2; exit 1; }

echo "   ▸ every route the product promises; the chat, as members, a moderator and an admin"
python3 - "$url" "$values" "$supabase_url" "$anon" "$work/apps/web" "$here/lib/chat-client.mjs" "$pgurl" <<'PY' \
  || { echo "FAIL: the routes or the chat; wrangler dev said:" >&2; tail -40 "$scratch/dev.log" >&2; exit 1; }
import html, http.client, json, re, subprocess, sys, time, urllib.error, urllib.request
base, values, supabase, anon, app, client, pgurl = sys.argv[1], json.load(open(sys.argv[2])), *sys.argv[3:]
name = values["productname"]
problems = []
def bad(m): problems.append(m)

def req(path, headers=None):
    # A GET whose CONNECTION drops (not one that answers an error) is asked
    # again, twice at most, and says so: `wrangler dev` on a loaded machine
    # has dropped one.
    for attempt in range(3):
        r = urllib.request.Request(base + path, headers=headers or {})
        try:
            with urllib.request.urlopen(r, timeout=60) as resp:
                return resp.status, resp.headers, resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            return e.code, e.headers, e.read().decode("utf-8", "replace")
        except (http.client.RemoteDisconnected, ConnectionResetError) as e:
            if attempt == 2:
                raise
            print(f"   (GET {path}: the connection dropped ({e.__class__.__name__}) — asking again)")
            time.sleep(1)
def text(page):
    # React separates adjacent text with `<!-- -->`: drop those, then tags.
    return html.unescape(re.sub(r"<[^>]+>", " ", re.sub(r"<!--.*?-->", "", page, flags=re.S)))
def title(page):
    # next/head marks what it renders: `<title data-next-head="">`.
    m = re.search(r"<title[^>]*>(.*?)</title>", page, re.S)
    return m and html.unescape(m.group(1))
def chat(*args):
    out = subprocess.run(["node", client, app, supabase, anon, *args], capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit(f"chat-client {args[0]} failed: {out.stderr.strip()[-400:]}")
    return json.loads(out.stdout)
def psql(sql):
    out = subprocess.run(["psql", pgurl, "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "-c", sql],
                         capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit(f"psql: {out.stderr.strip()[:300]}")
    return out.stdout.strip()

# ── the pages, under the product's own name ───────────────────────────────
s, _, home = req("/")
if s != 200:
    bad(f"/ answered {s}")
if title(home) != name:
    bad(f"the sign-in page's <title> is {title(home)!r}, not {name!r}")
h1 = re.search(r"<h1[^>]*>(.*?)</h1>", home, re.S)
if not h1 or html.unescape(re.sub(r"<!--.*?-->", "", h1.group(1))).strip() != name:
    bad(f"the sign-in page's heading is {h1 and h1.group(1)!r}, not {name!r}")
for want in ('type="password"', "Sign up", "Login"):
    if want not in home:
        bad(f"the sign-in page has no {want!r}")
if "Slack Clone" in text(home) and "Slack Clone" not in name:
    bad("the sign-in page still carries the baseline's name")
s, _, page = req("/channels/1")
if s != 200 or title(page) != name:
    bad(f"/channels/1 answered {s} titled {title(page)!r}")
s, _, _ = req("/no-such-page")
if s != 404:
    bad(f"/no-such-page answered {s}, not 404")
s, h, body = req("/api/health")
if s != 200 or json.loads(body) != {"ok": True, "auth": "reachable", "signup": "open",
                                    "emailConfirmation": "off", "schema": "migrated"} \
        or h.get("cache-control") != "no-store":
    bad(f"/api/health answered {s} {body} ({h.get('cache-control')})")

# ── sign-up: every user a member, the plus-addresses their roles ──────────
pw = "correct horse battery"
sam, kim, lee = "sam@chat.example", "kim+supamod@chat.example", "lee+supaadmin@chat.example"
want_roles = {sam: None, kim: "moderator", lee: "admin"}
ids = {}
for email, role in want_roles.items():
    up = chat("signup", email, pw)
    if not up["ok"] or up["userRole"] != role:
        bad(f"sign-up of {email} gave {up} — its session must carry user_role {role!r}")
    ids[email] = up.get("user")
wrong = chat("signin", sam, "not the password")
if wrong["ok"] or wrong["code"] != "invalid_credentials":
    bad(f"a wrong password was not refused: {wrong}")
again = chat("signin", kim, pw)
if not again["ok"] or again["userRole"] != "moderator":
    bad(f"kim signed in again without her role: {again}")

# ── the starter channels, their messages and their authors ───────────────
ch = chat("channels", sam, pw)
if not ch["ok"] or sorted(c["slug"] for c in ch["rows"]) != ["public", "random"]:
    bad(f"sam sees channels {ch.get('rows')}, not #public and #random")
public = next((c["id"] for c in ch.get("rows") or [] if c["slug"] == "public"), None)
msgs = chat("messages", sam, pw, str(public))
first = (msgs.get("rows") or [{}])[0]
if not msgs["ok"] or first.get("message") != "Hello World 👋" \
        or (first.get("author") or {}).get("username") != "supabot+supaadmin@example.com":
    bad(f"#public's first message is {first}, not the seed's, with its author")
seed_id = first.get("id")

# ── a message, posted by one member and read by another ──────────────────
post = chat("post", sam, pw, str(public), "hello from sam")
mine = (post.get("rows") or [{}])[0]
if not post["ok"] or mine.get("user_id") != ids[sam]:
    bad(f"sam's message did not post as sam: {post}")
seen = chat("messages", kim, pw, str(public))
last = (seen.get("rows") or [{}])[-1]
if last.get("message") != "hello from sam" or (last.get("author") or {}).get("username") != sam:
    bad(f"kim reads #public's last message as {last}, not sam's, by sam")
# …and nobody posts as somebody else: the insert policy is auth.uid().
as_sam = (f"SET ROLE authenticated; SELECT set_config('request.jwt.claims', "
          f"'{{\"sub\":\"{ids[sam]}\",\"role\":\"authenticated\"}}', false);")
w = subprocess.run(["psql", pgurl, "-X", "-q", "-At", "-c",
                    f"{as_sam} INSERT INTO public.messages (message, channel_id, user_id) "
                    f"VALUES ('as kim', {int(public)}, '{ids[kim]}')"], capture_output=True, text=True)
if "row-level security" not in w.stderr:
    bad(f"sam posted as kim, or was refused for another reason: {w.stderr.strip()[:160]}")
def exists(mid):
    return psql(f"select count(*) from public.messages where id = {int(mid)}") == "1"

# ── deletes, by role ──────────────────────────────────────────────────────
chat("delete-message", sam, pw, str(seed_id))
if not exists(seed_id):
    bad("a member deleted somebody else's message")
chat("delete-message", sam, pw, str(mine["id"]))
if exists(mine["id"]):
    bad("a member could not delete their own message")
other = (chat("post", sam, pw, str(public), "moderate me")["rows"] or [{}])[0]
chat("delete-message", kim, pw, str(other["id"]))
if exists(other["id"]):
    bad("a moderator could not delete a member's message")
added = chat("add-channel", sam, pw, "sams-room")
room = (added.get("rows") or [{}])[0]
if not added["ok"] or room.get("created_by") != ids[sam]:
    bad(f"sam could not add a channel: {added}")
def channel(cid):
    return psql(f"select count(*) from public.channels where id = {int(cid)}") == "1"
chat("delete-channel", kim, pw, str(room["id"]))
if not channel(room["id"]):
    bad("a moderator deleted a channel — only its creator and admins may")
chat("delete-channel", lee, pw, str(room["id"]))
if channel(room["id"]):
    bad("an admin could not delete a member's channel")
chat("delete-channel", sam, pw, str(public))
if not channel(public):
    bad("a member deleted #public")

# ── the bare publishable key reads nothing ────────────────────────────────
for table in ("channels", "messages", "users", "user_roles"):
    r = chat("anon", table)
    if r.get("rows"):
        bad(f"anon reads {table}: {r['rows'][:2]}")

# ── what Realtime streams ─────────────────────────────────────────────────
pub = psql("select string_agg(tablename, ',' order by tablename) from pg_publication_tables "
           "where pubname = 'supabase_realtime'")
if pub != "channels,messages,users":
    bad(f"the supabase_realtime publication carries {pub!r}, not channels, messages and users")
full = psql("select string_agg(relname || '=' || relreplident::text, ',' order by relname) from pg_class "
            "where relnamespace = 'public'::regnamespace and relname in ('channels','messages','users')")
if full != "channels=f,messages=f,users=f":
    bad(f"the streamed tables' replica identity is {full!r}, not full (a delete must carry its row)")

if problems:
    for p in problems:
        print(f"  ✕ {p}", file=sys.stderr)
    sys.exit(1)
print(f"   /, /channels/1 and a 404, titled {name!r}; /api/health ok; a member, a moderator and an "
      f"admin signed up with their roles in their sessions; #public and #random with the seed's "
      f"messages and authors; a message posted and read back by somebody else; deletes allowed "
      f"and refused by role; a channel added and removed; nothing for the bare publishable key; "
      f"three tables streamed with full row images")
PY

echo "e2e.test.sh: ok"
