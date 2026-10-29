#!/usr/bin/env python3
"""A stand-in for the Supabase endpoints this product touches, over a local
Postgres (testing/lib/local-postgres.sh).

    fake-supabase-api.py <port> <postgres-url> [--ref <project-ref>]
                         [--auth <superuser-url>] [--confirm-email]

Without `--auth` it is the Management API endpoints the migration runner
uses,

    POST /v1/projects/<ref>/database/query   {"query": "<sql>"}
    GET|PATCH /v1/projects/<ref>/config/auth  the project's Auth settings — the
                                              runner PATCHes the access-token
                                              hook on after the migrations

which hands the SQL to `psql` as the `postgres` role and answers the rows of
the last statement as a JSON array, an error as a non-2xx JSON `message`
carrying Postgres's own text. Only the bearer token's presence is checked.

`--auth <superuser-url>` adds what a PROJECT has before any migration runs and
what it answers on its own URL, as far as this app reaches it:

  the schemas Supabase creates itself, through the superuser URL: `auth`
               (`auth.users`, `auth.uid()`, `auth.role()`, `auth.jwt()`) and
               `storage` (`buckets`, `objects`, row-level security on), with
               the grants the template's migration needs from `postgres` — a
               foreign key to and a trigger on `auth.users`, a row in
               `storage.buckets`, policies on `storage.objects` (owned by
               `supabase_storage_admin`, which `postgres` is a member of) —
               so the migration means here what it means there;
  the access-token hook, as Auth runs it: once config/auth has
               hook_custom_access_token_enabled and a pg-functions:// URI, every
               access token /token and /signup issue is the hook function's
               answer, called as `supabase_auth_admin` with Auth's event
               ({user_id, claims, authentication_method}) — and a hook that
               fails fails the sign-in with 500 `unexpected_failure`, as Auth's
               does;
  /auth/v1/*   a GoTrue stand-in — settings, signup, token (password and
               refresh_token grants), user (GET, PUT), logout, recover,
               verify (token_hash), health, and the admin API's
               GET/DELETE /admin/users/<id> (service role only; a soft delete
               keeps the row, obfuscated, and the user can no longer sign
               in). Users are rows in `auth.users` of the same database, so
               the migration's trigger writes their profile as Supabase's
               would. Access tokens are HS256 JWTs with no `kid`, so
               supabase-js checks each one by calling GET /auth/v1/user — the
               path the app's safeGetSession() takes. Every /auth/v1 call must
               carry one of the project's API keys (`apikey`), as Supabase's
               gateway requires;
  /rest/v1/<table>
               a PostgREST stand-in for the calls the app's supabase-js makes:
               GET and HEAD (`select` of `*`, a column list or a many-to-one
               embed `alias:fk_column(*)` resolved through the foreign key,
               `eq`/`neq`/`is`
               filters, `order`, `limit`, `Prefer: count=exact` answered in
               Content-Range, `.single()`'s object Accept — one row or 406
               PGRST116), POST (insert; `resolution=merge-duplicates` upsert on
               the primary key or `on_conflict`; `return=representation` or
               minimal), PATCH (update) and DELETE, filtered the same way. The
               request's JWT (the user's, the anon key or the service-role
               key) becomes `SET LOCAL ROLE` and `request.jwt.claims`, exactly
               what PostgREST does, so row-level security decides — and the
               service role, BYPASSRLS as on Supabase, sees everything.

The keys are printed on stdout at startup as `anon-key <jwt>` and
`service-role-key <jwt>`. Email is never sent: what Supabase would mail is
kept, and GET /__fake/outbox reads it back. POST /__fake/config with
{"mailer_autoconfirm": bool, "email_allowed": [..] | null} switches whether
sign-up confirms at once (the default unless --confirm-email, as the
product's Terraform sets it), and models the built-in SMTP's members-only
rule (anyone else gets 400 `email_address_not_authorized`).
"""
import base64
import hashlib
import hmac
import http.server
import json
import re
import secrets
import subprocess
import sys
import threading
import time
import urllib.parse
import uuid

PORT = int(sys.argv[1])
DB = sys.argv[2]
REF = sys.argv[sys.argv.index("--ref") + 1] if "--ref" in sys.argv else None
ADMIN = sys.argv[sys.argv.index("--auth") + 1] if "--auth" in sys.argv else None
ROUTE = re.compile(r"^/v1/projects/([a-z0-9]+)/database/query$")
AUTH_CONFIG_ROUTE = re.compile(r"^/v1/projects/([a-z0-9]+)/config/auth$")
HOOK_URI = re.compile(r"^pg-functions://postgres/([a-z_][a-z0-9_]*)/([a-z_][a-z0-9_]*)$")
NAME = re.compile(r"^[a-z_][a-z0-9_]*$")
JWT_SECRET = secrets.token_hex(32).encode()
BASE = f"http://127.0.0.1:{PORT}"
CONFIG = {"mailer_autoconfirm": "--confirm-email" not in sys.argv, "email_allowed": None}
# The project's Auth config as the Management API keeps it (config/auth).
AUTH_CONFIG = {"hook_custom_access_token_enabled": False, "hook_custom_access_token_uri": None,
               "mailer_autoconfirm": CONFIG["mailer_autoconfirm"]}
OUTBOX: list = []
REFRESH: dict = {}
LOCK = threading.Lock()


def psql(sql: str, url: str = DB, **params) -> subprocess.CompletedProcess:
    argv = ["psql", url, "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1"]
    for k, v in params.items():
        argv += ["-v", f"{k}={v}"]
    return subprocess.run(argv, input=sql, capture_output=True, text=True)


def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def jwt_encode(claims: dict) -> str:
    head = b64(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
    body = b64(json.dumps(claims, separators=(",", ":")).encode())
    sig = hmac.new(JWT_SECRET, f"{head}.{body}".encode(), hashlib.sha256).digest()
    return f"{head}.{body}.{b64(sig)}"


def jwt_decode(token: str):
    try:
        head, body, sig = token.split(".")
        want = hmac.new(JWT_SECRET, f"{head}.{body}".encode(), hashlib.sha256).digest()
        if not hmac.compare_digest(b64(want), sig):
            return None
        claims = json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)))
        return claims if claims.get("exp", 0) > time.time() else None
    except Exception:
        return None


def api_key(role: str) -> str:
    now = int(time.time())
    return jwt_encode({"iss": "supabase-demo", "role": role, "iat": now, "exp": now + 10 * 365 * 86400})


ANON_KEY = api_key("anon")
SERVICE_KEY = api_key("service_role")

PROJECT_SCHEMAS = """
CREATE SCHEMA IF NOT EXISTS auth;
CREATE TABLE IF NOT EXISTS auth.users (
  id uuid PRIMARY KEY,
  email text UNIQUE NOT NULL,
  encrypted_password text,
  email_confirmed_at timestamptz,
  raw_user_meta_data jsonb NOT NULL DEFAULT '{}',
  last_sign_in_at timestamptz,
  deleted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT nullif(coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''),
                         (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')), '')::uuid
$$;
CREATE OR REPLACE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS $$
  SELECT coalesce(nullif(current_setting('request.jwt.claim.role', true), ''),
                  (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'))::text
$$;
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb
$$;
GRANT USAGE ON SCHEMA auth TO postgres, anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE, REFERENCES, TRIGGER ON auth.users TO postgres;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA auth TO PUBLIC;

-- Auth's own role: what a pg-functions:// hook runs as.
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'supabase_auth_admin') THEN
    CREATE ROLE supabase_auth_admin NOLOGIN NOINHERIT;
  END IF;
END $$;
GRANT USAGE ON SCHEMA auth TO supabase_auth_admin;

-- The extensions schema every project carries, with uuid-ossp in it.
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" SCHEMA extensions;
GRANT USAGE ON SCHEMA extensions TO postgres, anon, authenticated, service_role;

-- The (empty) publication Realtime listens to, owned by `postgres` as on a
-- project, so a migration may add tables to it or re-create it.
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    CREATE PUBLICATION supabase_realtime;
  END IF;
END $$;
ALTER PUBLICATION supabase_realtime OWNER TO postgres;

DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'supabase_storage_admin') THEN
    CREATE ROLE supabase_storage_admin NOLOGIN;
  END IF;
END $$;
CREATE SCHEMA IF NOT EXISTS storage AUTHORIZATION supabase_storage_admin;
CREATE TABLE IF NOT EXISTS storage.buckets (
  id text PRIMARY KEY,
  name text NOT NULL UNIQUE,
  owner uuid,
  public boolean DEFAULT false,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);
CREATE TABLE IF NOT EXISTS storage.objects (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bucket_id text REFERENCES storage.buckets (id),
  name text,
  owner uuid,
  metadata jsonb,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
ALTER TABLE storage.buckets OWNER TO supabase_storage_admin;
ALTER TABLE storage.objects OWNER TO supabase_storage_admin;
GRANT supabase_storage_admin TO postgres;
GRANT USAGE ON SCHEMA storage TO anon, authenticated, service_role;
GRANT ALL ON storage.buckets, storage.objects TO anon, authenticated, service_role;
"""

USER_JSON = """
SELECT json_build_object(
  'id', id, 'aud', 'authenticated', 'role', 'authenticated', 'email', email, 'phone', '',
  'email_confirmed_at', email_confirmed_at, 'confirmed_at', email_confirmed_at,
  'last_sign_in_at', last_sign_in_at,
  'app_metadata', json_build_object('provider', 'email', 'providers', json_build_array('email')),
  'user_metadata', raw_user_meta_data,
  'identities', json_build_array(json_build_object(
     'identity_id', id, 'id', id, 'user_id', id, 'provider', 'email',
     'identity_data', json_build_object('sub', id, 'email', email, 'email_verified', email_confirmed_at IS NOT NULL),
     'created_at', created_at, 'updated_at', updated_at, 'last_sign_in_at', last_sign_in_at)),
  'created_at', created_at, 'updated_at', updated_at, 'deleted_at', deleted_at, 'is_anonymous', false)
FROM auth.users"""


def hash_password(password: str) -> str:
    salt = secrets.token_hex(8)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), 10000).hex()
    return f"pbkdf2${salt}${digest}"


def check_password(password: str, stored: str) -> bool:
    try:
        _, salt, digest = stored.split("$")
    except ValueError:
        return False
    got = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), 10000).hex()
    return hmac.compare_digest(got, digest)


def user_by(where: str, **params):
    # A soft-deleted user is gone as far as Auth is concerned.
    run = psql(f"{USER_JSON} WHERE deleted_at IS NULL AND ({where});", ADMIN, **params)
    out = run.stdout.strip()
    return json.loads(out) if run.returncode == 0 and out else None


class HookFailed(Exception):
    pass


def run_hook(user_id: str, claims: dict) -> dict:
    """The access-token hook, as Auth runs one: as supabase_auth_admin, with
    Auth's event, its answer's `claims` the token's. Off until config/auth
    turns it on."""
    if not AUTH_CONFIG.get("hook_custom_access_token_enabled"):
        return claims
    m = HOOK_URI.match(AUTH_CONFIG.get("hook_custom_access_token_uri") or "")
    if not m:
        raise HookFailed(f"unsupported hook URI {AUTH_CONFIG.get('hook_custom_access_token_uri')!r}")
    event = {"user_id": user_id, "claims": claims, "authentication_method": "password"}
    run = psql(f"SET ROLE supabase_auth_admin;\nSELECT {m.group(1)}.{m.group(2)}(:'event'::jsonb)::text;",
               ADMIN, event=json.dumps(event))
    lines = run.stdout.strip().splitlines()
    if run.returncode != 0 or not lines:
        raise HookFailed(run.stderr.strip() or "the hook answered nothing")
    answer = json.loads(lines[-1])
    if not isinstance(answer.get("claims"), dict):
        raise HookFailed("the hook's answer has no claims object")
    return answer["claims"]


def session_for(user: dict) -> dict:
    now = int(time.time())
    claims = {"aud": "authenticated", "exp": now + 3600, "iat": now, "iss": f"{BASE}/auth/v1",
              "sub": user["id"], "email": user["email"], "phone": "", "role": "authenticated",
              "aal": "aal1", "amr": [{"method": "password", "timestamp": now}],
              "app_metadata": user["app_metadata"], "user_metadata": user["user_metadata"],
              "session_id": str(uuid.uuid4()), "is_anonymous": False}
    claims = run_hook(user["id"], claims)
    refresh = secrets.token_urlsafe(24)
    with LOCK:
        REFRESH[refresh] = user["id"]
    psql("UPDATE auth.users SET last_sign_in_at = now() WHERE id = :'id';", ADMIN, id=user["id"])
    return {"access_token": jwt_encode(claims), "token_type": "bearer", "expires_in": 3600,
            "expires_at": now + 3600, "refresh_token": refresh, "user": user}


def may_email(email: str) -> bool:
    allowed = CONFIG["email_allowed"]
    return allowed is None or email in allowed


def mail(email: str, kind: str, redirect_to):
    token_hash = secrets.token_hex(28)
    with LOCK:
        OUTBOX.append({"email": email, "type": kind, "token_hash": token_hash, "redirect_to": redirect_to})


# ── PostgREST: the query string a supabase-js call becomes ────────────────
RESERVED = {"select", "order", "limit", "offset", "on_conflict", "columns"}


class Refused(Exception):
    def __init__(self, status, body):
        super().__init__(body.get("message"))
        self.status, self.body = status, body


def ident(name: str) -> str:
    name = name.strip().strip('"')
    if not NAME.match(name):
        raise Refused(400, {"code": "PGRST100", "message": f"unsupported identifier {name!r}"})
    return f'"{name}"'


def where_clause(pairs, params: dict) -> str:
    conds = []
    for key, value in pairs:
        if key in RESERVED:
            continue
        col = ident(key)
        neg = False
        op, _, arg = value.partition(".")
        if op == "not":
            neg = True
            op, _, arg = arg.partition(".")
        if op in ("eq", "neq"):
            p = f"p{len(params)}"
            params[p] = arg
            cond = f"{col} {'=' if op == 'eq' else '<>'} :'{p}'"
        elif op == "is" and arg in ("null", "true", "false"):
            cond = f"{col} IS {arg.upper()}"
        else:
            raise Refused(400, {"code": "PGRST100", "message": f"unsupported filter {key}={value}"})
        conds.append(f"NOT ({cond})" if neg else cond)
    return " AND ".join(conds) or "true"


EMBED = re.compile(r"^(?:([a-z_][a-z0-9_]*):)?([a-z_][a-z0-9_]*)\((.*)\)$", re.S)


def split_top(select: str) -> list:
    """A select list's items, split on the commas outside parentheses."""
    items, depth, cur = [], 0, ""
    for ch in select:
        if ch == "," and depth == 0:
            items.append(cur.strip())
            cur = ""
            continue
        depth += {"(": 1, ")": -1}.get(ch, 0)
        cur += ch
    if cur.strip():
        items.append(cur.strip())
    return items


def foreign_key(table: str, column: str):
    """The table and column a public.<table>.<column> foreign key points at."""
    run = psql("SELECT c.confrelid::regclass::text || ' ' || ra.attname FROM pg_constraint c "
               "JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1] "
               "JOIN pg_attribute ra ON ra.attrelid = c.confrelid AND ra.attnum = c.confkey[1] "
               "WHERE c.contype = 'f' AND c.conrelid = ('public.' || :'t')::regclass "
               "AND array_length(c.conkey, 1) = 1 AND a.attname = :'c';", ADMIN, t=table, c=column)
    out = run.stdout.split()
    if run.returncode != 0 or len(out) != 2:
        raise Refused(400, {"code": "PGRST200", "message": f"no relationship from {table}.{column}"})
    ref = out[0] if "." in out[0] else f"public.{out[0]}"
    return ref, out[1]


def select_list(select: str, table: str, src: str, depth: int = 0) -> str:
    """PostgREST's select: `*`, columns, and many-to-one embeds
    (`author:user_id(*)`) resolved through the column's foreign key, the
    embedded row a JSON object (null when there is none) read under the same
    role, so its own row-level security applies."""
    if depth > 3:
        raise Refused(400, {"code": "PGRST100", "message": "embeds nest too deep"})
    out = []
    for item in split_top(select.strip() or "*"):
        if item == "*":
            out.append(f"{src}.*")
            continue
        m = EMBED.match(item)
        if not m:
            out.append(f"{src}.{ident(item)}")
            continue
        alias, column, inner = m.group(1) or m.group(2), m.group(2), m.group(3)
        ref, refcol = foreign_key(table, column)
        ref_table = ref.split(".", 1)[1]
        inner_src = f"e{depth}"
        out.append(f"(SELECT row_to_json(x{depth}) FROM (SELECT {select_list(inner, ref_table, inner_src, depth + 1)} "
                   f"FROM {ref} AS {inner_src} WHERE {inner_src}.{ident(refcol)} = {src}.{ident(column)}) x{depth}) AS {ident(alias)}")
    return ", ".join(out)


def order_of(order: str) -> str:
    if not order:
        return ""
    parts = []
    for term in order.split(","):
        col, _, direction = term.partition(".")
        parts.append(f"{ident(col)} {'DESC' if direction.startswith('desc') else 'ASC'}")
    return " ORDER BY " + ", ".join(parts)


def primary_key(table: str) -> list:
    run = psql("SELECT a.attname FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid "
               "AND a.attnum = ANY(i.indkey) WHERE i.indrelid = ('public.' || :'t')::regclass "
               "AND i.indisprimary ORDER BY a.attnum;", ADMIN, t=table)
    return [ident(c) for c in run.stdout.split()] if run.returncode == 0 else []


def as_role(claims: dict, sql: str, **params) -> subprocess.CompletedProcess:
    role = claims.get("role")
    if role not in ("anon", "authenticated", "service_role"):
        role = "anon"
    return psql(f"BEGIN; SET LOCAL ROLE {role}; "
                f"SELECT set_config('request.jwt.claims', :'claims', true) \\g /dev/null\n"
                f"{sql}\nCOMMIT;", DB, claims=json.dumps(claims), **params)


def pg_error(run: subprocess.CompletedProcess, claims: dict) -> Refused:
    msg = re.sub(r"^(psql:<stdin>:\d+: )?ERROR:\s+", "", run.stderr.strip().splitlines()[0] if run.stderr.strip() else "")
    if "row-level security" in msg or "permission denied" in msg:
        status = 401 if claims.get("role") == "anon" else 403
        return Refused(status, {"code": "42501", "details": None, "hint": None, "message": msg})
    if "duplicate key" in msg:
        return Refused(409, {"code": "23505", "details": None, "hint": None, "message": msg})
    # A table the schema does not have is not in PostgREST's schema cache: it
    # answers 404 PGRST205 — what a project's Data API says before the
    # migrations ran.
    missing = re.match(r'relation "(?:public\.)?([^"]+)" does not exist', msg)
    if missing:
        return Refused(404, {"code": "PGRST205", "details": None, "hint": None,
                             "message": f"Could not find the table 'public.{missing.group(1)}' in the schema cache"})
    return Refused(400, {"code": "PGRST000", "details": None, "hint": None, "message": msg})


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # quiet: the e2e prints what matters
        pass

    def answer(self, status: int, body=None, headers=None, raw: bytes = None) -> None:
        data = raw if raw is not None else (b"" if body is None else json.dumps(body).encode())
        self.send_response(status)
        self.send_header("content-type", "application/json; charset=utf-8")
        self.send_header("content-length", str(len(data)))
        self.send_header("x-supabase-api-version", "2024-01-01")
        # Supabase's gateway answers every origin, with CORS headers: the
        # chat calls the project from the browser, which enforces them.
        self.send_header("access-control-allow-origin", "*")
        self.send_header("access-control-expose-headers", "content-range, x-supabase-api-version")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def fail(self, status: int, code: str, msg: str) -> None:
        self.answer(status, {"code": code, "error_code": code, "msg": msg})

    def body(self):
        return json.loads(self.raw or b"{}")

    def bearer(self):
        auth = self.headers.get("authorization") or ""
        return auth[7:] if auth.lower().startswith("bearer ") else None

    # ── routing ──────────────────────────────────────────────────────────
    def route(self, method: str) -> None:
        # The body is read before anything answers: the connection is kept
        # alive, and an unread body would be the next request's first bytes.
        self.raw = self.rfile.read(int(self.headers.get("content-length") or 0))
        url = urllib.parse.urlsplit(self.path)
        path = url.path
        pairs = urllib.parse.parse_qsl(url.query, keep_blank_values=True)
        query = dict(pairs)
        if method == "POST" and ROUTE.match(path):
            return self.management_query(path)
        if method in ("GET", "PATCH") and AUTH_CONFIG_ROUTE.match(path):
            return self.management_auth_config(method, path)
        if ADMIN and path.startswith("/__fake/"):
            return self.fake_admin(method, path)
        if ADMIN and path.startswith("/auth/v1/"):
            if self.headers.get("apikey") not in (ANON_KEY, SERVICE_KEY):
                return self.answer(401, {"message": "Invalid API key"})
            try:
                return self.auth(method, path[len("/auth/v1"):], query)
            except HookFailed as e:
                return self.answer(500, {"code": 500, "error_code": "unexpected_failure",
                                         "msg": f"Error running hook URI: {e}"})
        if ADMIN and path.startswith("/rest/v1/"):
            if self.headers.get("apikey") not in (ANON_KEY, SERVICE_KEY):
                return self.answer(401, {"message": "Invalid API key"})
            try:
                return self.rest(method, path[len("/rest/v1/"):], pairs)
            except Refused as r:
                return self.answer(r.status, r.body)
        return self.answer(404, {"message": f"no such endpoint {method} {path}"})

    def handle_route(self, method: str) -> None:
        try:
            self.route(method)
        except Exception as e:  # a stand-in that drops the connection hides what broke
            self.answer(500, {"message": f"fake-supabase-api: {e.__class__.__name__}: {e}"})

    def do_OPTIONS(self):  # a browser's preflight, as the gateway answers it
        self.rfile.read(int(self.headers.get("content-length") or 0))
        self.answer(204, None, {
            "access-control-allow-methods": "GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS",
            "access-control-allow-headers": self.headers.get("access-control-request-headers") or "*",
            "access-control-max-age": "3600"})

    def do_GET(self):
        self.handle_route("GET")

    def do_HEAD(self):
        self.handle_route("HEAD")

    def do_POST(self):
        self.handle_route("POST")

    def do_PUT(self):
        self.handle_route("PUT")

    def do_PATCH(self):
        self.handle_route("PATCH")

    def do_DELETE(self):
        self.handle_route("DELETE")

    # ── the Management API's query endpoint ──────────────────────────────
    def management_query(self, path: str) -> None:
        m = ROUTE.match(path)
        if REF and m.group(1) != REF:
            return self.answer(404, {"message": f"no such project {m.group(1)}"})
        if not self.bearer():
            return self.answer(401, {"message": "missing bearer token"})
        query = self.body()["query"]
        # A read returns its rows; anything else runs as written and returns
        # none, as the real endpoint does for DDL.
        if re.match(r"^\s*select\b", query, re.I):
            run = psql(f"select coalesce(json_agg(t), '[]'::json) from ({query.rstrip().rstrip(';')}) t;")
        else:
            run = psql(query)
        if run.returncode != 0:
            return self.answer(400, {"message": run.stderr.strip()})
        out = run.stdout.strip()
        return self.answer(201, json.loads(out) if out.startswith("[") else [])

    # ── the Management API's Auth config ─────────────────────────────────
    def management_auth_config(self, method: str, path: str) -> None:
        m = AUTH_CONFIG_ROUTE.match(path)
        if REF and m.group(1) != REF:
            return self.answer(404, {"message": f"no such project {m.group(1)}"})
        if not self.bearer():
            return self.answer(401, {"message": "missing bearer token"})
        if method == "PATCH":
            body = self.body()
            uri = body.get("hook_custom_access_token_uri")
            if uri is not None and not HOOK_URI.match(uri) and not uri.startswith("https://"):
                return self.answer(400, {"message": f"invalid hook_custom_access_token_uri {uri!r}"})
            with LOCK:
                AUTH_CONFIG.update(body)
                if "mailer_autoconfirm" in body:
                    CONFIG["mailer_autoconfirm"] = bool(body["mailer_autoconfirm"])
        with LOCK:
            return self.answer(200, dict(AUTH_CONFIG))

    # ── what the e2e reads back and switches ─────────────────────────────
    def fake_admin(self, method: str, path: str) -> None:
        if path == "/__fake/outbox" and method == "GET":
            with LOCK:
                return self.answer(200, list(OUTBOX))
        if path == "/__fake/config" and method == "POST":
            CONFIG.update({k: v for k, v in self.body().items() if k in CONFIG})
            return self.answer(200, CONFIG)
        return self.answer(404, {"message": "no such fake endpoint"})

    # ── GoTrue ───────────────────────────────────────────────────────────
    def auth(self, method: str, path: str, query: dict) -> None:
        if path == "/health" and method == "GET":
            return self.answer(200, {"version": "fake", "name": "GoTrue", "description": "stand-in"})
        if path == "/settings" and method == "GET":
            return self.answer(200, {
                "external": {"email": True, "phone": False, "anonymous_users": False},
                "disable_signup": False, "mailer_autoconfirm": CONFIG["mailer_autoconfirm"],
                "phone_autoconfirm": False, "sms_provider": "", "saml_enabled": False})
        if path == "/.well-known/jwks.json" and method == "GET":
            return self.answer(200, {"keys": []})
        if path == "/signup" and method == "POST":
            return self.signup(self.body(), query.get("redirect_to"))
        if path == "/token" and method == "POST":
            return self.token(query.get("grant_type"), self.body())
        if path.startswith("/admin/users/"):
            return self.admin_user(method, path[len("/admin/users/"):])
        if path == "/user":
            claims = jwt_decode(self.bearer() or "")
            if not claims or claims.get("role") != "authenticated":
                return self.fail(403, "bad_jwt", "invalid JWT: unable to parse or verify signature")
            user = user_by("id = :'id'", id=claims["sub"])
            if not user:
                return self.fail(403, "user_not_found", "User from sub claim in JWT does not exist")
            if method == "GET":
                return self.answer(200, user)
            if method == "PUT":
                body = self.body()
                if body.get("password"):
                    psql("UPDATE auth.users SET encrypted_password = :'pw', updated_at = now() WHERE id = :'id';",
                         ADMIN, pw=hash_password(body["password"]), id=user["id"])
                return self.answer(200, user_by("id = :'id'", id=user["id"]))
        if path == "/logout" and method == "POST":
            return self.answer(204)
        if path == "/recover" and method == "POST":
            email = (self.body().get("email") or "").lower()
            if not may_email(email):
                return self.fail(400, "email_address_not_authorized",
                                 f'Email address "{email}" cannot be used as it is not authorized')
            if user_by("email = :'email'", email=email):
                mail(email, "recovery", query.get("redirect_to"))
            return self.answer(200, {})
        if path == "/verify" and method == "POST":
            body = self.body()
            with LOCK:
                hit = next((m for m in OUTBOX if m["token_hash"] == body.get("token_hash")
                            and not m.get("used")), None)
                if hit:
                    hit["used"] = True
            if not hit:
                return self.fail(403, "otp_expired", "Email link is invalid or has expired")
            psql("UPDATE auth.users SET email_confirmed_at = coalesce(email_confirmed_at, now()) "
                 "WHERE email = :'email';", ADMIN, email=hit["email"])
            return self.answer(200, session_for(user_by("email = :'email'", email=hit["email"])))
        return self.answer(404, {"message": f"no such auth endpoint {method} {path}"})

    def admin_user(self, method: str, uid: str) -> None:
        claims = jwt_decode(self.bearer() or "")
        if not claims or claims.get("role") != "service_role":
            return self.fail(403, "not_admin", "User not allowed")
        try:
            uid = str(uuid.UUID(uid))
        except ValueError:
            return self.fail(400, "validation_failed", "user id must be a UUID")
        user = user_by("id = :'id'", id=uid)
        if not user:
            return self.fail(404, "user_not_found", "User not found")
        if method == "GET":
            return self.answer(200, user)
        if method == "DELETE":
            if self.body().get("should_soft_delete"):
                # GoTrue's soft delete: the row stays (so nothing cascades),
                # its email is obfuscated and Auth treats the user as gone.
                run = psql("UPDATE auth.users SET deleted_at = now(), updated_at = now(), "
                           "email = 'deleted-' || id || '@deleted.invalid' WHERE id = :'id';", ADMIN, id=uid)
            else:
                run = psql("DELETE FROM auth.users WHERE id = :'id';", ADMIN, id=uid)
            if run.returncode != 0:
                return self.answer(500, {"message": run.stderr.strip()})
            return self.answer(200, user)
        return self.answer(405, {"message": f"{method} /admin/users/<id> is not supported"})

    def signup(self, body: dict, redirect_to) -> None:
        email, password = (body.get("email") or "").lower(), body.get("password") or ""
        if not re.match(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", email):
            return self.fail(400, "validation_failed", "Unable to validate email address: invalid format")
        if len(password) < 6:
            return self.answer(422, {"code": "weak_password", "msg": "Password should be at least 6 characters.",
                                     "weak_password": {"reasons": ["length"]}})
        if user_by("email = :'email'", email=email):
            return self.fail(422, "user_already_exists", "User already registered")
        confirm = not CONFIG["mailer_autoconfirm"]
        if confirm and not may_email(email):
            return self.fail(400, "email_address_not_authorized",
                             f'Email address "{email}" cannot be used as it is not authorized')
        uid = str(uuid.uuid4())
        run = psql("INSERT INTO auth.users (id, email, encrypted_password, email_confirmed_at, raw_user_meta_data) "
                   "VALUES (:'id', :'email', :'pw', " + ("NULL" if confirm else "now()") + ", :'meta');",
                   ADMIN, id=uid, email=email, pw=hash_password(password), meta=json.dumps(body.get("data") or {}))
        if run.returncode != 0:
            return self.answer(500, {"message": run.stderr.strip()})
        user = user_by("id = :'id'", id=uid)
        if confirm:
            mail(email, "signup", redirect_to)
            return self.answer(200, user)
        return self.answer(200, session_for(user))

    def token(self, grant: str, body: dict) -> None:
        if grant == "password":
            email = (body.get("email") or "").lower()
            run = psql("SELECT encrypted_password, email_confirmed_at IS NOT NULL FROM auth.users "
                       "WHERE email = :'email' AND deleted_at IS NULL;", ADMIN, email=email)
            row = run.stdout.strip().split("|") if run.stdout.strip() else None
            if not row or not check_password(body.get("password") or "", row[0]):
                return self.fail(400, "invalid_credentials", "Invalid login credentials")
            if row[1] != "t":
                return self.fail(400, "email_not_confirmed", "Email not confirmed")
            return self.answer(200, session_for(user_by("email = :'email'", email=email)))
        if grant == "refresh_token":
            with LOCK:
                uid = REFRESH.pop(body.get("refresh_token") or "", None)
            user = uid and user_by("id = :'id'", id=uid)
            if not user:
                return self.fail(400, "refresh_token_not_found", "Invalid Refresh Token: Refresh Token Not Found")
            return self.answer(200, session_for(user))
        return self.fail(400, "unsupported_grant_type", f"unsupported grant_type {grant!r}")

    # ── PostgREST ────────────────────────────────────────────────────────
    def rest(self, method: str, table: str, pairs: list) -> None:
        if not NAME.match(table):
            raise Refused(400, {"message": "bad table name"})
        claims = jwt_decode(self.bearer() or self.headers.get("apikey") or "")
        if not claims:
            raise Refused(401, {"code": "PGRST301", "message": "JWT invalid"})
        query = dict(pairs)
        prefer = {p.strip() for p in (self.headers.get("prefer") or "").split(",") if p.strip()}
        single = "application/vnd.pgrst.object+json" in (self.headers.get("accept") or "")
        params: dict = {}
        where = where_clause(pairs, params)
        rel = f'public.{ident(table)}'
        returning = "return=representation" in prefer

        if method in ("GET", "HEAD"):
            limit = f" LIMIT {int(query['limit'])}" if query.get("limit", "").isdigit() else ""
            # jsonb, not json: json_agg breaks lines between rows, and the
            # answer is read back as one line.
            sql = (f"SELECT jsonb_build_object('rows', coalesce((SELECT jsonb_agg(t) FROM (SELECT {select_list(query.get('select', '*'), table, 'src')} "
                   f"FROM {rel} AS src WHERE {where}{order_of(query.get('order', ''))}{limit}) t), '[]'::jsonb), "
                   f"'count', (SELECT count(*) FROM {rel} WHERE {where}))::text;")
            status = 200
        elif method == "POST":
            body = self.body()
            rows = body if isinstance(body, list) else [body]
            cols = [ident(c) for c in (query["columns"].split(",") if query.get("columns")
                                      else dict.fromkeys(k for r in rows for k in r))]
            if not cols:
                raise Refused(400, {"message": "nothing to insert"})
            params["body"] = json.dumps(rows)
            conflict = ""
            if "resolution=merge-duplicates" in prefer or "resolution=ignore-duplicates" in prefer:
                target = [ident(c) for c in query["on_conflict"].split(",")] if query.get("on_conflict") else primary_key(table)
                if "resolution=ignore-duplicates" in prefer:
                    conflict = f" ON CONFLICT ({', '.join(target)}) DO NOTHING"
                else:
                    conflict = (f" ON CONFLICT ({', '.join(target)}) DO UPDATE SET "
                                + ", ".join(f"{c} = EXCLUDED.{c}" for c in cols))
            insert = (f"INSERT INTO {rel} ({', '.join(cols)}) SELECT {', '.join(cols)} "
                      f"FROM json_populate_recordset(NULL::{rel}, :'body'){conflict}")
            sql = self.write(insert, returning, query, table)
            status = 201
        elif method == "PATCH":
            body = self.body()
            cols = [ident(c) for c in body]
            if not cols:
                raise Refused(400, {"message": "nothing to update"})
            params["body"] = json.dumps(body)
            update = (f"UPDATE {rel} SET ({', '.join(cols)}) = (SELECT {', '.join(cols)} "
                      f"FROM json_populate_record(NULL::{rel}, :'body')) WHERE {where}")
            sql = self.write(update, returning, query, table)
            status = 200 if returning else 204
        elif method == "DELETE":
            sql = self.write(f"DELETE FROM {rel} WHERE {where}", returning, query, table)
            status = 200 if returning else 204
        else:
            raise Refused(405, {"message": f"{method} is not supported"})

        run = as_role(claims, sql, **params)
        if run.returncode != 0:
            raise pg_error(run, claims)
        lines = run.stdout.strip().splitlines()
        result = json.loads(lines[-1]) if lines else {"rows": [], "count": 0}
        data, count = result.get("rows") or [], result.get("count")
        headers = {}
        if count is not None:
            total = count if any(p.startswith("count=") for p in prefer) or method in ("GET", "HEAD") else "*"
            headers["content-range"] = f"0-{len(data) - 1}/{total}" if data else f"*/{total}"
        if method in ("GET", "HEAD") or returning:
            if single:
                if len(data) != 1:
                    raise Refused(406, {"code": "PGRST116", "details": f"The result contains {len(data)} rows",
                                        "hint": None, "message": "JSON object requested, multiple (or no) rows returned"})
                return self.answer(status, data[0], headers)
            return self.answer(status, data, headers)
        return self.answer(status, None, headers)

    @staticmethod
    def write(statement: str, returning: bool, query: dict, table: str) -> str:
        if returning:
            cols = select_list(query.get("select", "*"), table, "w")
            return (f"WITH w AS ({statement} RETURNING *) SELECT jsonb_build_object('rows', "
                    f"coalesce((SELECT jsonb_agg(t) FROM (SELECT {cols} FROM w) t), '[]'::jsonb), "
                    f"'count', (SELECT count(*) FROM w))::text;")
        # return=minimal: no RETURNING, so no SELECT policy is asked — as
        # PostgREST does it.
        return f"{statement};"


if ADMIN:
    run = psql(PROJECT_SCHEMAS, ADMIN)
    if run.returncode != 0:
        sys.exit(f"fake-supabase-api: could not create the project's auth and storage schemas: {run.stderr.strip()}")
    print(f"anon-key {ANON_KEY}", flush=True)
    print(f"service-role-key {SERVICE_KEY}", flush=True)
http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
