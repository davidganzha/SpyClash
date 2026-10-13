-- Full application services for the isolated staging project.
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

-- Private application records. Only the authenticated Edge service may mutate.
create schema if not exists app_private;
revoke all on schema app_private from public, anon, authenticated;
create table if not exists app_private.profiles (
  user_id uuid primary key,
  state text not null default 'active' check (state in ('active','deleting','deleted')),
  contact_email text not null default '',
  spy_id text unique check (spy_id ~ '^[0-9]{3}-[0-9]{3}$'),
  data jsonb not null default '{}',
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
-- Compatible with the account gate's bootstrap table.
alter table app_private.profiles add column if not exists spy_id text;
create unique index if not exists app_profiles_spy_id_unique on app_private.profiles(spy_id) where spy_id is not null;
create table if not exists app_private.friendships (
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null references app_private.profiles(user_id),
  addressee_id uuid not null references app_private.profiles(user_id),
  pair_low uuid generated always as (least(requester_id,addressee_id)) stored,
  pair_high uuid generated always as (greatest(requester_id,addressee_id)) stored,
  status text not null check(status in ('pending','accepted','declined','blocked')),
  blocked_by_id uuid, request_event_id uuid,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(pair_low,pair_high), check(requester_id<>addressee_id),
  check ((status='blocked' and blocked_by_id in (requester_id,addressee_id)) or (status<>'blocked' and blocked_by_id is null))
);
create index if not exists app_friendships_addressee on app_private.friendships(addressee_id,status);
create index if not exists app_friendships_requester on app_private.friendships(requester_id,status);
create table if not exists app_private.profile_comments (
  id uuid primary key default gen_random_uuid(), target_user_id uuid not null references app_private.profiles(user_id),
  author_user_id uuid not null references app_private.profiles(user_id), body text not null check(length(body) between 1 and 280),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), check(target_user_id<>author_user_id)
);
create index if not exists app_comments_target on app_private.profile_comments(target_user_id,created_at desc,id);
create index if not exists app_comments_author on app_private.profile_comments(author_user_id,created_at desc);
create table if not exists app_private.community_reports (
  id uuid primary key default gen_random_uuid(), reporter_user_id uuid, reported_user_id uuid, comment_id uuid,
  report_type text not null check(report_type in ('user','comment')),
  reason text not null check(reason in ('harassment','hate_speech','sexual_content','violence_or_threats','spam','impersonation','other')),
  details text not null default '' check(length(details)<=500), content_snapshot text not null check(length(content_snapshot)<=500),
  status text not null default 'open' check(status in ('open','reviewing','actioned','dismissed')),
  data jsonb not null default '{}', created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create unique index if not exists app_reports_pending_unique on app_private.community_reports(reporter_user_id,reported_user_id,report_type,coalesce(comment_id,'00000000-0000-0000-0000-000000000000'::uuid)) where status in ('open','reviewing');
create table if not exists app_private.room_invites (
  id uuid primary key default gen_random_uuid(), sender_user_id uuid not null references app_private.profiles(user_id),
  recipient_user_id uuid not null references app_private.profiles(user_id), room_id uuid not null references full_game_private.rooms(id),
  room_code text not null, status text not null check(status in ('pending','accepted','declined','expired')),
  notification_event_id uuid not null, created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(sender_user_id,recipient_user_id,room_id), check(sender_user_id<>recipient_user_id)
);
create index if not exists app_invites_recipient on app_private.room_invites(recipient_user_id,status,created_at desc);
create table if not exists app_private.notification_events (
  id uuid primary key, event_type text not null check(event_type in ('friend_request','room_invite')),
  source_id uuid not null, actor_id uuid not null, recipient_id uuid not null, room_id uuid,
  visible boolean not null default true, data jsonb not null default '{}', created_at timestamptz not null default now(),
  unique(event_type,source_id,recipient_id)
);
create index if not exists app_events_recipient on app_private.notification_events(recipient_id,created_at desc,id) where visible;
create table if not exists app_private.notification_announcements (
  id uuid primary key default gen_random_uuid(), request_id uuid unique not null, author_id uuid not null,
  status text not null check(status in ('draft','published','withdrawn')), revision uuid not null,
  data jsonb not null, published_at timestamptz, expires_at timestamptz not null,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index if not exists app_announcements_published on app_private.notification_announcements(published_at desc,id) where status='published';
create table if not exists app_private.notification_read_receipts (
  user_id uuid not null references app_private.profiles(user_id), notification_key text not null, read_at timestamptz not null,
  primary key(user_id,notification_key)
);
create table if not exists app_private.profile_watchers (
  viewer_id uuid not null references app_private.profiles(user_id), profile_id uuid not null references app_private.profiles(user_id),
  last_seen_at timestamptz not null, primary key(viewer_id,profile_id)
);
create index if not exists app_profile_watchers_target on app_private.profile_watchers(profile_id,last_seen_at);
create table if not exists public.app_profile_signals (
  recipient_user_id uuid not null, profile_user_id uuid not null, revision bigint not null default 1,
  updated_at timestamptz not null default now(), primary key(recipient_user_id,profile_user_id)
);
create table if not exists public.app_user_signals (
  recipient_user_id uuid primary key, revision bigint not null default 1, updated_at timestamptz not null default now()
);
alter table public.app_profile_signals enable row level security;
alter table public.app_user_signals enable row level security;
revoke all on public.app_profile_signals,public.app_user_signals from public,anon,authenticated;
grant select on public.app_profile_signals,public.app_user_signals to authenticated;
drop policy if exists app_profile_signal_recipient on public.app_profile_signals;
create policy app_profile_signal_recipient on public.app_profile_signals for select to authenticated using(recipient_user_id=(select auth.uid()));
drop policy if exists app_user_signal_recipient on public.app_user_signals;
create policy app_user_signal_recipient on public.app_user_signals for select to authenticated using(recipient_user_id=(select auth.uid()));
do $$ declare t text; begin
  foreach t in array array['profiles','friendships','profile_comments','community_reports','room_invites','notification_events','notification_announcements','notification_read_receipts','profile_watchers'] loop
    execute format('alter table app_private.%I enable row level security',t);
    execute format('revoke all on app_private.%I from public,anon,authenticated',t);
  end loop;
end $$;
do $$ begin
  if exists(select 1 from pg_publication where pubname='supabase_realtime') then
    if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='app_profile_signals') then alter publication supabase_realtime add table public.app_profile_signals; end if;
    if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='app_user_signals') then alter publication supabase_realtime add table public.app_user_signals; end if;
  end if;
end $$;

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
