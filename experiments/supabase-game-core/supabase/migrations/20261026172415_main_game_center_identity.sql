-- Main SpyClash Game Center identities. Private server-only ownership and replay defense.
-- Apply this additive migration only after explicit approval for the target environment.
do $$
begin
  if to_regclass('app_private.profiles') is null
    or to_regclass('app_private.legacy_links') is null
    or to_regclass('app_private.legacy_session_accounts') is null
    or to_regclass('app_private.main_account_deletions') is null then
    raise exception 'Game Center requires the existing app schema and 20261013010810_main_account_deletion_intent.sql first';
  end if;
end;
$$;

create schema if not exists game_center_private;
revoke all on schema game_center_private from public, anon, authenticated;

create table if not exists game_center_private.accounts (
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
alter table game_center_private.accounts enable row level security;
revoke all on game_center_private.accounts from public, anon, authenticated;

create table if not exists game_center_private.used_assertions (
  replay_key text primary key check(replay_key ~ '^[0-9a-f]{64}$'),
  expires_at timestamptz not null
);
create index if not exists game_center_assertion_expiry on game_center_private.used_assertions(expires_at);
alter table game_center_private.used_assertions enable row level security;
revoke all on game_center_private.used_assertions from public, anon, authenticated;

-- Durable native generation results and quota reservations. Provider leases
-- expire for recovery; logical requests and their quota are never duplicated.
create table if not exists game_center_private.generation_requests (
  user_id uuid not null references game_center_private.accounts(user_id),
  request_id uuid not null,
  request_hash text not null check(request_hash ~ '^[0-9a-f]{64}$'),
  usage_date date not null,
  charged boolean not null default true,
  state text not null check(state in ('pending','complete','failed')),
  lease_id uuid,
  lease_until timestamptz,
  result jsonb,
  error_code text,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  primary key(user_id,request_id),
  check((lease_id is null) = (lease_until is null)),
  check((state='complete') = (result is not null))
);
create index if not exists game_center_generation_usage on game_center_private.generation_requests(user_id,usage_date) where charged;
alter table game_center_private.generation_requests enable row level security;
revoke all on game_center_private.generation_requests from public, anon, authenticated;
