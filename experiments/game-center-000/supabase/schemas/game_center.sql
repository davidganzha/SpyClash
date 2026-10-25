-- Experimental Game Center identity data. Apply only to the isolated local/test project.
-- This is a schema source, not an invented Supabase migration history entry.
create schema if not exists gc000_private;
revoke all on schema gc000_private from public, anon, authenticated;

create table if not exists gc000_private.accounts (
  identity_key text primary key check(identity_key ~ '^[0-9a-f]{64}$'),
  user_id uuid not null unique,
  shadow_email text not null unique,
  state text not null default 'pending' check(state in ('pending','ready','deleted')),
  lease_id uuid,
  lease_until timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check((lease_id is null) = (lease_until is null))
);
alter table gc000_private.accounts enable row level security;
revoke all on gc000_private.accounts from public, anon, authenticated;

create table if not exists gc000_private.used_assertions (
  replay_key text primary key check(replay_key ~ '^[0-9a-f]{64}$'),
  expires_at timestamptz not null
);
create index if not exists gc000_assertion_expiry on gc000_private.used_assertions(expires_at);
alter table gc000_private.used_assertions enable row level security;
revoke all on gc000_private.used_assertions from public, anon, authenticated;
