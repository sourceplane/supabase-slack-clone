#!/usr/bin/env bash
# THE REBRAND WRITES EACH VALUE ONCE, AND WHAT IT WROTE STAYS WRITTEN.
#
# Drives the real tooling/rebrand/rebrand.mjs over one-file trees and compares
# the file. Each case is a shape this baseline's identity actually takes in the
# tree — the name seam, the worker name, the Worker's own origin (the one the
# Supabase project's Auth sends its links to), the placeholder domain, a
# secret ref, the `repo` the Supabase project is named after — and each runs
# through as many passes as a bootstrap might make, so a value written once must survive every later pass
# unchanged. What must NOT be renamed: the upstream example's own link, a
# migration (its checksum is in the manifest and in every project it was
# applied to), and what merely spells `supabase` — a wiring token names the
# component, not this baseline.
#
# The identity is PINNED (fixtures/baseline-identity.supabase-slack-clone.json) rather
# than read from .baseline/identity.json: what this tests is the engine, and
# its fixtures spell the identity out literally.
#
# Needs: node, git. No network.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
rebrand="$here/../tooling/rebrand/rebrand.mjs"
identity="$here/fixtures/baseline-identity.supabase-slack-clone.json"

fail=0
# check NAME VALUES-JSON FILE CONTENT WANT [PASSES]
check() {
  local name="$1" values="$2" file="$3" content="$4" want="$5" passes="${6:-1}"
  local tmp got out i
  tmp="$(mktemp -d)"
  git -C "$tmp" init -q
  mkdir -p "$tmp/$(dirname "$file")" "$tmp/.rebrand"
  printf '%s\n' "$content" > "$tmp/$file"
  printf '%s\n' "$values" > "$tmp/.rebrand/values.json"
  for ((i = 1; i <= passes; i++)); do
    git -C "$tmp" add -A
    if ! out="$(cd "$tmp" && node "$rebrand" --baseline-identity "$identity" --values .rebrand/values.json --allow-dirty 2>&1)"; then
      echo "   ✕  $name: rebrand pass $i failed:" >&2
      printf '%s\n' "$out" | sed 's/^/        /' >&2
      fail=1
      rm -rf "$tmp"
      return
    fi
  done
  got="$(cat "$tmp/$file")"
  rm -rf "$tmp"
  if [ "$got" = "$want" ]; then
    echo "   ok  $name"
  else
    echo "   ✕  $name:" >&2
    echo "        got:  $got" >&2
    echo "        want: $want" >&2
    fail=1
  fi
}

acme='{"reponame":"acme-chat","productname":"Acme Chat","productdomain":"acme.dev","githuborg":"acme-inc","subdomain":"acme","orunWorkspace":"ws_79BDXAZQ"}'

echo "── rebrand: the product's own identity"
check "the name seam takes the product's name" \
  "$acme" apps/web/lib/site.ts 'export const SITE_NAME = "Slack Clone"' \
  'export const SITE_NAME = "Acme Chat"'
check "…and stays a valid string for a name with an apostrophe and an ampersand" \
  '{"reponame":"sams-chat","productname":"Sam'"'"'s Chat & Co","productdomain":"sam.dev"}' \
  apps/web/lib/site.ts 'export const SITE_NAME = "Slack Clone"' \
  'export const SITE_NAME = "Sam'"'"'s Chat & Co"'
check "the display name elsewhere is content, and is left alone" \
  "$acme" apps/web/app/x.tsx '<p>Welcome to the Slack Clone.</p>' \
  '<p>Welcome to the Slack Clone.</p>'
check "the worker name is re-prefixed, the environment suffix kept" \
  "$acme" apps/web/component.yaml 'workerName: supabase-slack-clone-web' \
  'workerName: acme-chat-web'
check "the Worker's own origin: worker name and subdomain" \
  "$acme" intent.yaml '    url: https://supabase-slack-clone-web-stage.your-workers-subdomain.workers.dev' \
  '    url: https://acme-chat-web-stage.acme.workers.dev'
check "the subdomain the deploy's smoke reaches the Worker on" \
  "$acme" apps/web/component.yaml '    workersDevSubdomain: your-workers-subdomain' \
  '    workersDevSubdomain: acme'
check "the subdomain the Supabase project's Auth Site URL is built from" \
  "$acme" infra/terraform/supabase/component.yaml '    workersDevSubdomain: your-workers-subdomain' \
  '    workersDevSubdomain: acme'
check "the placeholder domain is the product's domain, not a renamed slug" \
  "$acme" intent.yaml '      BASE_DOMAIN: supabase-slack-clone.example.com' \
  '      BASE_DOMAIN: acme.dev'
check "no domain given: the reserved placeholder, for an owner to replace later" \
  '{"reponame":"acme-chat","productname":"Acme Chat","githuborg":"acme-inc","subdomain":"acme"}' \
  intent.yaml '      BASE_DOMAIN: supabase-slack-clone.example.com' \
  '      BASE_DOMAIN: acme-chat.example.com'
check "an empty domain is no domain" \
  '{"reponame":"acme-chat","productname":"Acme Chat","productdomain":""}' \
  intent.yaml '      BASE_DOMAIN: supabase-slack-clone.example.com' \
  '      BASE_DOMAIN: acme-chat.example.com'
check "the repo slug" \
  "$acme" package.json '  "name": "supabase-slack-clone",' \
  '  "name": "acme-chat",'
check "the repo Terraform names the Supabase project after" \
  "$acme" intent.yaml '        repo: supabase-slack-clone' \
  '        repo: acme-chat'
check "…and the Terraform variable's default" \
  "$acme" infra/terraform/supabase/terraform/main.tf '  default = "supabase-slack-clone"' \
  '  default = "acme-chat"'
check "a secret ref names the product's workspace and project" \
  "$acme" apps/web/component.yaml \
  '    WIRING_SUPABASE_STAGE: "secret://supabase-slack-clone/supabase-slack-clone/stage/WIRING_SUPABASE"' \
  '    WIRING_SUPABASE_STAGE: "secret://ws_79BDXAZQ/acme-chat/stage/WIRING_SUPABASE"'
check "this repository's source link names the product's owner and repository" \
  "$acme" README.md 'See https://github.com/sourceplane/supabase-slack-clone.' \
  'See https://github.com/acme-inc/acme-chat.'
check "a migration is never rewritten (its checksum is in the manifest and in every project it was applied to)" \
  "$acme" packages/db/src/migrations/040_x/up.sql '-- supabase-slack-clone: a comment the checksum covers' \
  '-- supabase-slack-clone: a comment the checksum covers'
check "org-owned identity is not renamed" \
  "$acme" intent.yaml 'apiVersion: sourceplane.io/v1 # mail ops@sourceplane.ai' \
  'apiVersion: sourceplane.io/v1 # mail ops@sourceplane.ai'

echo "── rebrand: what is not this baseline's"
check "a wiring token names the component, not the baseline" \
  "$acme" apps/web/wrangler.template.jsonc \
  '    "NEXT_PUBLIC_SUPABASE_URL": "@@wiring(supabase/__ENV__:supabase_url)@@",' \
  '    "NEXT_PUBLIC_SUPABASE_URL": "@@wiring(supabase/__ENV__:supabase_url)@@",'
check "the upstream example's home is upstream's" \
  "$acme" README.md '[Slack clone](https://github.com/supabase/supabase/tree/master/examples/slack-clone/nextjs-slack-clone)' \
  '[Slack clone](https://github.com/supabase/supabase/tree/master/examples/slack-clone/nextjs-slack-clone)'

echo "── rebrand: a written value is not rewritten, in any later pass"
contains='{"reponame":"supabase-slack-clone-2","productname":"Slack Clone 2","productdomain":"supabase-slack-clone.example.com.au","githuborg":"sourceplane","subdomain":"your-workers-subdomain-2"}'
check "a repo slug containing the baseline's slug survives three passes" \
  "$contains" package.json '  "name": "supabase-slack-clone",' \
  '  "name": "supabase-slack-clone-2",' 3
check "a worker name built on it survives three passes" \
  "$contains" apps/web/component.yaml 'workerName: supabase-slack-clone-web' \
  'workerName: supabase-slack-clone-2-web' 3
check "a domain containing the baseline's domain survives three passes" \
  "$contains" intent.yaml 'BASE_DOMAIN: supabase-slack-clone.example.com' \
  'BASE_DOMAIN: supabase-slack-clone.example.com.au' 3
check "a subdomain containing the placeholder survives three passes" \
  "$contains" infra/terraform/supabase/component.yaml 'workersDevSubdomain: your-workers-subdomain' \
  'workersDevSubdomain: your-workers-subdomain-2' 3
check "a name containing the baseline's name survives three passes" \
  "$contains" apps/web/lib/site.ts 'export const SITE_NAME = "Slack Clone"' \
  'export const SITE_NAME = "Slack Clone 2"' 3

# --verify runs after every rebrand. Without the product's values it cannot
# tell the product's own identity from a leftover; with them it can. A real
# leftover must fail it either way.
verify() { # NAME VALUES FILE CONTENT WANT(pass|fail) [--values]
  local name="$1" values="$2" file="$3" content="$4" want="$5" withvalues="${6:-}" tmp got
  tmp="$(mktemp -d)"
  git -C "$tmp" init -q
  mkdir -p "$tmp/$(dirname "$file")" "$tmp/.rebrand"
  printf '%s\n' "$content" > "$tmp/$file"
  printf '%s\n' "$values" > "$tmp/.rebrand/values.json"
  git -C "$tmp" add -A
  if (cd "$tmp" && node "$rebrand" --baseline-identity "$identity" --verify ${withvalues:+--values .rebrand/values.json} >/dev/null 2>&1); then got=pass; else got=fail; fi
  rm -rf "$tmp"
  if [ "$got" = "$want" ]; then echo "   ok  $name"; else echo "   ✕  $name: --verify ${got}ed, want $want" >&2; fail=1; fi
}
echo "── rebrand --verify: the product's own identity is not residue"
verify "given the values, a slug containing the baseline's passes" \
  "$contains" package.json '"name": "supabase-slack-clone-2"' pass --values
verify "without them it cannot know, and fails" \
  "$contains" package.json '"name": "supabase-slack-clone-2"' fail
verify "given the values, a real leftover still fails" \
  "$acme" package.json '"name": "supabase-slack-clone"' fail --values
verify "a leftover worker name fails" \
  "$acme" apps/web/component.yaml 'workerName: supabase-slack-clone-web' fail --values
verify "a leftover code identifier fails (no rule renames it — so nothing may spell it)" \
  "$acme" apps/web/app/x.ts 'export class SupabaseSlackClone {}' fail --values
verify "the upstream example's links are not residue" \
  "$acme" apps/web/README.md 'the [example](https://github.com/supabase/supabase/tree/master/examples/slack-clone/nextjs-slack-clone)' pass --values
verify "a clean product passes" \
  "$acme" package.json '"name": "acme-chat"' pass --values

echo "── rebrand: a residue it cannot rename fails the rebrand itself"
tmp="$(mktemp -d)"; git -C "$tmp" init -q; mkdir -p "$tmp/.rebrand" "$tmp/apps/web"
printf '%s\n' "$acme" > "$tmp/.rebrand/values.json"
printf 'const x = "SUPABASE_SLACK_CLONE_TOKEN"\n' > "$tmp/apps/web/x.ts"
git -C "$tmp" add -A
if (cd "$tmp" && node "$rebrand" --baseline-identity "$identity" --values .rebrand/values.json --allow-dirty >/dev/null 2>&1); then
  echo "   ✕  an unrenamable env-var prefix passed the rebrand" >&2; fail=1
else
  echo "   ok  an unrenamable env-var prefix fails the rebrand, naming the file"
fi
rm -rf "$tmp"

[ "$fail" -eq 0 ] || exit 1
echo "rebrand.test.sh: ok"
