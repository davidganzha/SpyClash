create schema if not exists app_private;
revoke all on schema app_private from public, anon, authenticated;

create table if not exists app_private.receipts (
  actor_id uuid not null,
  request_id uuid not null,
  request_hash text not null,
  status integer not null check (status between 200 and 499),
  response jsonb not null,
  created_at timestamptz not null default clock_timestamp(),
  primary key(actor_id, request_id)
);
create table if not exists app_private.lifecycle_jobs (
  user_id uuid primary key,
  phase text not null default 'revoke_auth' check(phase in ('revoke_auth','delete_auth','complete')),
  attempts integer not null default 0,
  next_attempt_at timestamptz not null default clock_timestamp(),
  lease_until timestamptz,
  lease_id uuid,
  last_error text,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp()
);
alter table app_private.lifecycle_jobs add column if not exists lease_id uuid;
alter table app_private.receipts enable row level security;
alter table app_private.lifecycle_jobs enable row level security;
revoke all on all tables in schema app_private from public, anon, authenticated;

-- A deletion intent is an account fence, not a stored provider credential.
create table if not exists app_private.main_account_deletions (
  user_id uuid primary key,
  request_id uuid not null,
  legacy_user_id text not null,
  source_origin text not null,
  source_app_id text not null,
  phase text not null default 'pending' check (phase in ('pending','legacy_deleted','complete')),
  manual_apple_revocation_required boolean not null default false,
  lease_id uuid,
  lease_until timestamptz,
  last_error text,
  attempts integer not null default 0,
  next_attempt_at timestamptz not null default clock_timestamp(),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp()
);
alter table app_private.main_account_deletions add column if not exists attempts integer not null default 0;
alter table app_private.main_account_deletions add column if not exists next_attempt_at timestamptz not null default clock_timestamp();
alter table app_private.main_account_deletions enable row level security;
revoke all on app_private.main_account_deletions from public, anon, authenticated;
