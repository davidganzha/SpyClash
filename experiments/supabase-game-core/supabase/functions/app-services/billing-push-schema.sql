-- Private integration storage. Root migration creates app_private and profiles first.
create table if not exists app_private.entitlements (
  source_key text primary key, user_id uuid not null,
  active boolean not null default false, expires_at timestamptz,
  data jsonb not null default '{}', provider text not null,
  product_id text, provider_event_at timestamptz,
  updated_at timestamptz not null default clock_timestamp()
);
create index if not exists app_entitlements_owner on app_private.entitlements(user_id);
create table if not exists app_private.membership_grants (
  id uuid primary key default gen_random_uuid(), user_id uuid not null,
  active boolean not null default true, expires_at timestamptz,
  data jsonb not null default '{}', created_at timestamptz not null default clock_timestamp()
);
create index if not exists app_membership_grants_owner on app_private.membership_grants(user_id);
create table if not exists app_private.apple_accounts (
  user_id uuid primary key, app_account_token uuid not null unique,
  state text not null default 'active' check(state in ('active','deleted')),
  created_at timestamptz not null default clock_timestamp()
);
create table if not exists app_private.push_registrations (
  id uuid primary key default gen_random_uuid(), user_id uuid not null,
  installation_id text not null, kind text not null check(kind in ('device','push_to_start','activity')),
  binding text not null default '', room_id uuid, match_id text,
  bundle_id text not null, environment text not null check(environment in ('sandbox','production')),
  token_hash text not null, token_ciphertext jsonb not null,
  locale text not null default 'en', alert_authorized boolean not null default false,
  preferences jsonb not null default '{}', active boolean not null default true,
  updated_at timestamptz not null default clock_timestamp(),
  unique(installation_id,kind,binding), unique(bundle_id,environment,kind,token_hash)
);
create index if not exists app_push_owner on app_private.push_registrations(user_id) where active;
create table if not exists app_private.push_outbox (
  id uuid primary key default gen_random_uuid(), event_key text not null,
  registration_id uuid not null references app_private.push_registrations(id) on delete cascade,
  user_id uuid not null, room_id uuid, match_id text, payload jsonb not null,
  kind text not null default 'alert' check(kind in ('alert','liveactivity')),
  expires_at timestamptz not null, state text not null default 'pending'
    check(state in ('pending','sending','delivered','failed','cancelled')),
  attempts integer not null default 0, available_at timestamptz not null default clock_timestamp(),
  lease_id uuid, lease_until timestamptz, last_reason text,
  created_at timestamptz not null default clock_timestamp(), delivered_at timestamptz,
  unique(event_key,registration_id)
);
create index if not exists app_push_outbox_pending on app_private.push_outbox(available_at) where state in ('pending','sending');
create table if not exists app_private.legacy_links (
  user_id uuid primary key, legacy_user_id text not null unique,
  verified_at timestamptz not null, source_origin text not null,
  state text not null default 'active' check(state in ('active','deleted'))
);
create table if not exists app_private.legacy_operations (
  user_id uuid not null, request_id uuid not null, request_hash text not null,
  legacy_user_id text not null, state text not null default 'reserved'
    check(state in ('reserved','complete','failed')),
  response jsonb, created_at timestamptz not null default clock_timestamp(),
  primary key(user_id,request_id)
);
create table if not exists app_private.provider_revocations (
  id uuid primary key default gen_random_uuid(), user_id uuid not null,
  provider text not null, dedup_key text not null unique, data jsonb not null default '{}',
  state text not null default 'pending', created_at timestamptz not null default clock_timestamp()
);
alter table app_private.entitlements enable row level security;
alter table app_private.membership_grants enable row level security;
alter table app_private.apple_accounts enable row level security;
alter table app_private.push_registrations enable row level security;
alter table app_private.push_outbox enable row level security;
alter table app_private.legacy_links enable row level security;
alter table app_private.legacy_operations enable row level security;
alter table app_private.provider_revocations enable row level security;
revoke all on all tables in schema app_private from public, anon, authenticated;
