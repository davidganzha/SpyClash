-- Persistent reservations survive an Edge timeout after Auth created a user.
-- There are deliberately no auth.users foreign keys: deletion leaves an
-- immutable ownership tombstone and cannot rebind a legacy account.
create table if not exists app_private.legacy_session_accounts (
  identity_key text primary key check(identity_key ~ '^[a-f0-9]{64}$'),
  legacy_user_id text not null unique,
  source_origin text not null,
  source_app_id text not null,
  user_id uuid not null unique,
  shadow_email text not null unique,
  existing_link boolean not null default false,
  import_completed boolean not null default false,
  state text not null default 'reserved' check(state in ('reserved','ready')),
  lease_id uuid,
  lease_until timestamptz,
  last_verified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((lease_id is null) = (lease_until is null))
);
alter table app_private.legacy_session_accounts enable row level security;
revoke all on app_private.legacy_session_accounts from public, anon, authenticated;
