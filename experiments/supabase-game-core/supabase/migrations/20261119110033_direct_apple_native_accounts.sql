-- Direct Apple identities retain their historical Supabase UUID. No auth schema
-- writes and no inferred email linkage: only the reviewed bound-subject import.
create schema if not exists apple_private;
revoke all on schema apple_private from public,anon,authenticated;

create table app_private.native_accounts (
  user_id uuid primary key,
  provider text not null check(provider in ('game_center','apple')),
  identity_key text not null check(identity_key ~ '^[0-9a-f]{64}$'),
  state text not null check(state in ('pending','ready','deleting','deleted')),
  migration_complete boolean not null default false,
  migration_version integer not null default 0 check(migration_version>=0),
  legacy_user_id text,
  unique(provider,identity_key)
);
alter table app_private.native_accounts enable row level security;
revoke all on app_private.native_accounts from public,anon,authenticated;

create table apple_private.accounts (
  identity_key text primary key check(identity_key ~ '^[0-9a-f]{64}$'),
  subject_key text not null unique check(subject_key ~ '^apple-subject:[0-9a-f]{64}$'),
  client_id text not null check(client_id='com.spyclash.ios'),
  user_id uuid not null unique,
  shadow_email text not null unique,
  legacy_user_id text unique,
  state text not null default 'pending' check(state in ('pending','ready','deleting','deleted')),
  migration_version integer not null default 0 check(migration_version>=0),
  migration_complete boolean not null default false,
  lease_id uuid,
  lease_until timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check((lease_id is null)=(lease_until is null)),
  check(state<>'ready' or migration_complete),
  check(not migration_complete or migration_version>=1)
);
alter table apple_private.accounts enable row level security;
revoke all on apple_private.accounts from public,anon,authenticated;

-- GC and Apple source tables are the only writers of the private registry.
create function app_private.mirror_native_identity() returns trigger
language plpgsql security definer set search_path='' as $$
declare source_provider text:=case when TG_TABLE_SCHEMA='apple_private' then 'apple' else 'game_center' end;
begin
  if TG_OP='DELETE' then
    delete from app_private.native_accounts where user_id=OLD.user_id and provider=source_provider and identity_key=OLD.identity_key;
    return OLD;
  end if;
  if TG_OP='UPDATE' and (NEW.user_id<>OLD.user_id or NEW.identity_key<>OLD.identity_key) then
    raise exception 'native ownership is immutable';
  end if;
  if source_provider='apple' then
    if TG_OP='UPDATE' and (NEW.subject_key<>OLD.subject_key or NEW.legacy_user_id is distinct from OLD.legacy_user_id) then
      raise exception 'Apple subject provenance is immutable';
    end if;
    insert into app_private.native_accounts(user_id,provider,identity_key,state,migration_complete,migration_version,legacy_user_id)
      values(NEW.user_id,source_provider,NEW.identity_key,NEW.state,NEW.migration_complete,NEW.migration_version,NEW.legacy_user_id)
      on conflict(user_id) do update set state=excluded.state,migration_complete=excluded.migration_complete,migration_version=excluded.migration_version
      where app_private.native_accounts.provider=excluded.provider and app_private.native_accounts.identity_key=excluded.identity_key;
  else
    insert into app_private.native_accounts(user_id,provider,identity_key,state,migration_complete,migration_version)
      values(NEW.user_id,source_provider,NEW.identity_key,NEW.state,true,1)
      on conflict(user_id) do update set state=excluded.state
      where app_private.native_accounts.provider=excluded.provider and app_private.native_accounts.identity_key=excluded.identity_key;
  end if;
  if not found then raise exception 'conflicting native identity'; end if;
  return NEW;
end $$;
revoke all on function app_private.mirror_native_identity() from public,anon,authenticated;
create trigger apple_identity_registry after insert or update or delete on apple_private.accounts
  for each row execute function app_private.mirror_native_identity();
create trigger game_center_identity_registry after insert or update or delete on game_center_private.accounts
  for each row execute function app_private.mirror_native_identity();
insert into app_private.native_accounts(user_id,provider,identity_key,state,migration_complete,migration_version)
  select user_id,'game_center',identity_key,state,true,1 from game_center_private.accounts;

create table apple_private.attempts (
  request_id uuid primary key,
  identity_key text not null references apple_private.accounts(identity_key),
  nonce_hash text not null unique check(nonce_hash ~ '^[0-9a-f]{64}$'),
  code_hash text not null unique check(code_hash ~ '^[0-9a-f]{64}$'),
  state text not null check(state in ('reserved','exchanging','grant_stored','complete','failed','uncertain')),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  expires_at timestamptz not null
);
create index apple_attempt_account_state on apple_private.attempts(identity_key,state);
alter table apple_private.attempts enable row level security;
revoke all on apple_private.attempts from public,anon,authenticated;

-- Append grants; never overwrite an older, still revocable refresh credential.
create table apple_private.grants (
  id uuid primary key,
  user_id uuid not null references app_private.native_accounts(user_id),
  client_id text not null,
  ciphertext text not null,
  iv text not null,
  encryption_version text not null default 'apple-session-grant-v1',
  binding text,
  revision uuid not null default gen_random_uuid(),
  state text not null default 'active' check(state in ('active','revoking','revoked')),
  revoked_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check((state='revoked')=(revoked_at is not null))
);
create index apple_grant_account_state on apple_private.grants(user_id,state);
alter table apple_private.grants enable row level security;
revoke all on apple_private.grants from public,anon,authenticated;

create table apple_private.deletions (
  user_id uuid primary key references apple_private.accounts(user_id),
  request_id uuid not null unique,
  phase text not null default 'pending' check(phase in ('pending','verified','complete')),
  lease_id uuid,
  lease_until timestamptz,
  next_attempt_at timestamptz not null default clock_timestamp(),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check((lease_id is null)=(lease_until is null))
);
alter table apple_private.deletions enable row level security;
revoke all on apple_private.deletions from public,anon,authenticated;

-- Retain every attested historical App Store token, including duplicate source
-- account rows. One primary token remains in app_private.apple_accounts for new
-- checkouts; aliases never reassign a canonical transaction chain's owner.
create table apple_private.billing_token_aliases (
  app_account_token uuid primary key,
  user_id uuid not null references apple_private.accounts(user_id),
  source_record_id text not null unique,
  state text not null default 'active' check(state in ('active','deleted')),
  created_at timestamptz not null default clock_timestamp()
);
create index apple_billing_alias_owner on apple_private.billing_token_aliases(user_id);
alter table apple_private.billing_token_aliases enable row level security;
revoke all on apple_private.billing_token_aliases from public,anon,authenticated;

create table apple_private.migration_snapshots (
  user_id uuid primary key references apple_private.accounts(user_id),
  source_sha256 text not null check(source_sha256 ~ '^[0-9a-f]{64}$'),
  data jsonb not null,
  created_at timestamptz not null default clock_timestamp()
);
alter table apple_private.migration_snapshots enable row level security;
revoke all on apple_private.migration_snapshots from public,anon,authenticated;

-- Preserve existing ledgers/IDs. Both verified native providers can own quota;
-- adding a fabricated Game Center identity for Apple is expressly unnecessary.
do $$
declare target text; constraint_name text;
begin
  foreach target in array array['generation_requests','generation_reward_attempts','generation_reward_enrollments'] loop
    if to_regclass('game_center_private.'||target) is null then raise exception 'required native ledger missing: %',target; end if;
    for constraint_name in
      select conname from pg_constraint where conrelid=to_regclass('game_center_private.'||target)
        and contype='f' and confrelid='game_center_private.accounts'::regclass
    loop execute format('alter table game_center_private.%I drop constraint %I',target,constraint_name); end loop;
    execute format('alter table game_center_private.%I add constraint %I foreign key(user_id) references app_private.native_accounts(user_id)%s',
      target,target||'_native_user_fkey',case when target='generation_reward_enrollments' then ' on delete cascade' else '' end);
  end loop;
end $$;
