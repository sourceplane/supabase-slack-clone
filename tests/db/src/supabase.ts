// What a Supabase project has before any migration runs, as far as this
// schema touches it: the API roles and Auth's own role, `auth.users` with
// `auth.uid()`, `auth.role()` and `auth.jwt()`, the `extensions` schema's
// uuid_generate_v4(), and the empty `supabase_realtime` publication Supabase
// creates for every project. Supabase creates these itself; a test database
// needs them for upstream's migrations to mean here what they mean there (a
// trigger on auth.users, policies keyed on the request's JWT, a hook function
// only Auth may run, a publication the migration re-creates).
//
// auth.uid(), auth.role() and auth.jwt() read the request's JWT the way
// Supabase's own do: PostgREST sets `request.jwt.claims` for every request.
export const SUPABASE_PRELUDE = `
create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;
create role supabase_auth_admin nologin;

create schema auth;
create table auth.users (
  id uuid primary key default gen_random_uuid(),
  email text,
  encrypted_password text,
  raw_user_meta_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create function auth.uid() returns uuid language sql stable as $$
  select nullif(
    coalesce(
      current_setting('request.jwt.claim.sub', true),
      (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
    ),
    ''
  )::uuid
$$;
create function auth.role() returns text language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
  )::text
$$;
create function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb
$$;

create schema extensions;
create function extensions.uuid_generate_v4() returns uuid language sql volatile as $$
  select gen_random_uuid()
$$;

create publication supabase_realtime;

grant usage on schema public, auth to anon, authenticated, service_role;
grant usage on schema auth to supabase_auth_admin;
grant execute on all functions in schema auth to anon, authenticated, supabase_auth_admin;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
`;
